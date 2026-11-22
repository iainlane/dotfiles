import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { runInNewContext } from "node:vm";

const workflows = process.env.CUPBOARD_WORKFLOWS ?? ".github/workflows";
const bash = process.env.CUPBOARD_WORKFLOWS_BASH ?? "/bin/bash";

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError("Expected a workflow object.");
  }

  return Object.fromEntries(Object.entries(value));
}

function workflow(filename: string): Record<string, unknown> {
  const result = spawnSync("yq", ["-o=json", ".", join(workflows, filename)], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  const parsed: unknown = JSON.parse(result.stdout);
  return record(parsed);
}

function string(value: unknown): string {
  assert.equal(typeof value, "string");
  return String(value);
}

interface SubstituterConfiguration {
  readonly substituters: readonly string[];
  readonly trustedPublicKeys: readonly string[];
}

function nixConfigurationText(installable: string): string {
  const files: Readonly<Record<string, string | undefined>> = {
    ".#nix.substituterConfig": process.env.CUPBOARD_SHARED_NIX_CONFIG,
    ".#nix.publishSubstituterConfig": process.env.CUPBOARD_PUBLISH_CACHE_CONFIG,
    ".#nix.ciConfig": process.env.CUPBOARD_CI_NIX_CONFIG,
    ".#nix.publishCiConfig": process.env.CUPBOARD_PUBLISH_NIX_CONFIG,
  };
  const file = files[installable];

  if (file !== undefined) return readFileSync(file, "utf8");

  const result = spawnSync("nix", ["eval", "--raw", installable], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

function nixConfiguration(installable: string): SubstituterConfiguration {
  const settings = Object.fromEntries(
    nixConfigurationText(installable)
      .trim()
      .split("\n")
      .map((line) => {
        const [key, value] = line.split(" = ");
        return [key, value];
      }),
  );
  return {
    substituters: string(settings["extra-substituters"]).split(" "),
    trustedPublicKeys: string(settings["extra-trusted-public-keys"]).split(" "),
  };
}

// A flake for the fake `nix`: the value of each attribute that `nix eval`
// reads, and the output path of each installable that `nix build` builds.
// When `importsFromDerivation` is set, evaluating any attribute needs a build.
interface FakeFlake {
  readonly attributes?: Readonly<Record<string, unknown>>;
  readonly outputs?: Readonly<Record<string, string>>;
  readonly importsFromDerivation?: boolean;
}

const importedDerivation =
  "/nix/store/00000000000000000000000000000000-imported.drv";

// Writes a fake `nix` for the given flake into the directory, with the
// evaluation gate and its policy at the paths that the workflows use, and
// returns the environment that the fake reads. Like Nix, the fake applies
// `allow-import-from-derivation` from NIX_CONFIG, where a later line wins, and
// then from `--option`. An evaluation that imports from a derivation builds
// it when the setting allows that and fails otherwise. `nix build` links
// `--out-link` to the first output, and `<out-link>-<n>` to each later one.
function fakeNix(directory: string, flake: FakeFlake): NodeJS.ProcessEnv {
  const file = join(directory, "flake.json");
  writeFileSync(file, JSON.stringify(flake));
  const script = join(directory, "scripts/check-evaluation.bash");
  mkdirSync(dirname(script), { recursive: true });
  // The Nix build sandbox has no /usr/bin/env, so give the script the bash
  // that runs the workflow steps as its interpreter.
  writeFileSync(
    script,
    readFileSync(
      process.env.CUPBOARD_EVALUATION_SCRIPT ?? "scripts/check-evaluation.bash",
      "utf8",
    ).replace(/^#!.*\n/, `#!${bash}\n`),
    { mode: 0o755 },
  );

  const config = join(directory, "lib/nix/evaluation.conf");
  mkdirSync(dirname(config), { recursive: true });
  copyFileSync(
    process.env.CUPBOARD_EVALUATION_CONFIG ?? "lib/nix/evaluation.conf",
    config,
  );
  writeFileSync(
    join(directory, "nix"),
    `#!${process.execPath}
const { readFileSync, symlinkSync } = require("node:fs");
const flake = JSON.parse(readFileSync(process.env.FAKE_FLAKE, "utf8"));
const [command, ...args] = process.argv.slice(2);
const installables = args.filter((arg) => arg.startsWith(".#"));

function fail(message) {
  process.stderr.write("error: " + message + "\\n");
  process.exit(1);
}

let importFromDerivation = "true";
for (const line of (process.env.NIX_CONFIG ?? "").split("\\n")) {
  const [name, value] = line.split(" = ");
  if (name === "allow-import-from-derivation") importFromDerivation = value;
}
args.forEach((arg, index) => {
  if (arg === "--option" && args[index + 1] === "allow-import-from-derivation") {
    importFromDerivation = args[index + 2];
  }
});

if (command === "eval") {
  const attributes = flake.attributes ?? {};
  if (!(installables[0] in attributes)) {
    fail("flake does not provide attribute '" + installables[0] + "'");
  }
  if (flake.importsFromDerivation) {
    if (importFromDerivation !== "true") {
      fail("cannot build '${importedDerivation}' during evaluation because the option 'allow-import-from-derivation' is disabled");
    }
    process.stderr.write("building '${importedDerivation}'...\\n");
  }
  const value = attributes[installables[0]];
  process.stdout.write(args.includes("--json") ? JSON.stringify(value) : String(value));
} else if (command === "build") {
  const outputs = flake.outputs ?? {};
  const link = args[args.indexOf("--out-link") + 1];
  for (const installable of installables) {
    if (!(installable in outputs)) {
      fail("flake does not provide attribute '" + installable + "'");
    }
  }
  installables.forEach((installable, index) => {
    symlinkSync(outputs[installable], index === 0 ? link : link + "-" + index);
  });
} else {
  fail("unsupported command " + command);
}
`,
    { mode: 0o755 },
  );
  return { FAKE_FLAKE: file };
}

interface Event {
  readonly name: string;
  readonly action?: string;
  readonly fork?: boolean;
  readonly number?: number;
  readonly ref?: string;
}

function evaluate(expression: string, event: Event): unknown {
  return runInNewContext(expression, {
    github: {
      event_name: event.name,
      repository_id: "585180069",
      ref: event.ref ?? "refs/heads/main",
      event: {
        action: event.action ?? "",
        pull_request: {
          number:
            event.name === "pull_request" ? (event.number ?? 17) : undefined,
          head: { repo: { id: event.fork ? 123 : 585180069 } },
        },
      },
    },
  });
}

function allows(condition: unknown, event: Event): boolean {
  if (condition === undefined) return true;

  const expression = string(condition)
    .replace(/^\s*\$\{\{/, "")
    .replace(/\}\}\s*$/, "");
  const result = evaluate(expression, event);
  assert.equal(typeof result, "boolean");
  return result === true;
}

const caller = workflow("cupboard.yml");
const jobs = record(caller.jobs);
const wrapper = workflow("cupboard-publish.yml");
const sources = record(record(wrapper.jobs).sources);
assert.ok(Array.isArray(sources.steps));
const steps = sources.steps.map(record);
const evaluation = steps.find((step) => step.id === "publish-inputs");
assert.ok(evaluation);

function admittedJobs(event: Event): Record<string, boolean> {
  return {
    validation:
      allows(record(jobs["validation-plan"]).if, event) &&
      allows(record(jobs.validation).if, event),
    publish: allows(record(jobs.publish).if, event),
  };
}

// The event that starts a run of an update workflow. A manual run without an
// input uses the input's declared default.
interface Trigger {
  readonly event: "schedule" | "workflow_dispatch";
  readonly schedule?: string;
  readonly inputs?: Readonly<Record<string, boolean>>;
}

interface Commit {
  readonly author: string;
  readonly subject: string;
  readonly files: Readonly<Record<string, string>>;
}

interface UpdateRun {
  status: number | null;
  stderr: string;
  body: string | null;
  summary: string | null;
  pushed: Readonly<Record<string, Commit>>;
}

function runGit(cwd: string, env: NodeJS.ProcessEnv, args: string[]): string {
  const result = spawnSync("git", args, { cwd, encoding: "utf8", env });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

// The commit at the tip of each branch in a bare repository, keyed by ref,
// with its files keyed by path.
function branches(
  origin: string,
  env: NodeJS.ProcessEnv,
): Record<string, Commit> {
  const refs = runGit(origin, env, ["for-each-ref", "--format=%(refname)"])
    .split("\n")
    .filter((ref) => ref !== "");
  return Object.fromEntries(
    refs.map((ref) => [
      ref,
      {
        author: runGit(origin, env, ["log", "-1", "--format=%an <%ae>", ref]),
        subject: runGit(origin, env, ["log", "-1", "--format=%s", ref]),
        files: Object.fromEntries(
          runGit(origin, env, ["ls-tree", "-r", "--name-only", ref])
            .split("\n")
            .filter((path) => path !== "")
            .map((path) => [
              path,
              runGit(origin, env, ["show", `${ref}:${path}`]),
            ]),
        ),
      },
    ]),
  );
}

// Replaces each `${{ expression }}` in a workflow value with its value in the
// given contexts. JavaScript would read the hyphen in a property such as
// `inputs.maintain-lockfiles` as subtraction, so such a property becomes an
// index. GitHub renders a missing value as an empty string.
function interpolate(value: string, contexts: Record<string, unknown>): string {
  return value.replace(
    /\$\{\{([\s\S]*?)\}\}/g,
    (_match: string, expression: string) => {
      const result: unknown = runInNewContext(
        expression.replace(/\.([A-Za-z_]\w*(?:-\w+)+)/g, '["$1"]'),
        contexts,
      );
      return result === undefined || result === null ? "" : String(result);
    },
  );
}

function triggerContexts(
  definition: Record<string, unknown>,
  trigger: Trigger,
): Record<string, unknown> {
  const dispatch = record(definition.on).workflow_dispatch;
  const declared =
    dispatch === null || dispatch === undefined
      ? {}
      : record(record(dispatch).inputs ?? {});
  const defaults = Object.fromEntries(
    Object.entries(declared).map(([name, input]) => [
      name,
      record(input).default,
    ]),
  );
  return {
    github: {
      token: "fixture-token",
      event_name: trigger.event,
      event: { schedule: trigger.schedule },
    },
    inputs:
      trigger.event === "workflow_dispatch"
        ? { ...defaults, ...trigger.inputs }
        : {},
    secrets: {},
  };
}

function quote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

// Runs the `update` job's steps after the secrets setup, each in its own shell
// with its `env` evaluated for the trigger, as on a runner. `nix`, `gh` and
// `date` are stubs, and `runner` is the body of the update runner that `nix
// build` provides. The job runs in a Git repository whose first commit
// contains the given files. Its `origin` is a bare repository with a branch
// for each of `remoteBranches`, and the result includes the commit at the tip
// of each branch that `origin` has after the job.
function runUpdateWorkflow(
  filename: string,
  trigger: Trigger,
  runner: string,
  repository: Readonly<Record<string, string>>,
  options: { branches?: readonly string[]; createStatus?: number } = {},
): UpdateRun {
  const directory = mkdtempSync(join(tmpdir(), "update-workflow-"));
  const bin = join(directory, "bin");
  const log = join(directory, "log");
  const work = join(directory, "work");
  const origin = join(directory, "origin.git");
  const runnerTemp = join(directory, "temp");
  for (const path of [bin, log, work, runnerTemp]) mkdirSync(path);

  // Git hooks and `git rebase --exec` can set variables such as `GIT_DIR` and
  // `GIT_INDEX_FILE`, which would point the fixture's Git commands at the
  // caller's repository.
  const env: NodeJS.ProcessEnv = {
    ...Object.fromEntries(
      Object.entries(process.env).filter(([name]) => !name.startsWith("GIT_")),
    ),
    HOME: directory,
    XDG_CONFIG_HOME: join(directory, "config"),
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
  };

  writeFileSync(
    join(bin, "summary"),
    `#!${bash}
set -euo pipefail
printf 'before=%s; after=%s\\n' "$(cat "$1")" "$(cat "$2")"
`,
    { mode: 0o755 },
  );

  for (const [path, contents] of Object.entries(repository)) {
    mkdirSync(dirname(join(work, path)), { recursive: true });
    writeFileSync(join(work, path), contents);
  }

  runGit(directory, env, ["init", "--quiet", "--bare", origin]);
  runGit(work, env, ["init", "--quiet", "--initial-branch=main"]);
  runGit(work, env, ["add", "-A"]);
  runGit(work, env, [
    "-c",
    "user.name=fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "commit",
    "--quiet",
    "-m",
    "fixture",
  ]);
  runGit(work, env, ["remote", "add", "origin", origin]);
  mkdirSync(join(work, "scripts"), { recursive: true });
  copyFileSync(
    process.env.CUPBOARD_UPDATE_PUBLISHER ?? "scripts/publish-update-pr.bash",
    join(work, "scripts/publish-update-pr.bash"),
  );
  for (const branch of options.branches ?? []) {
    runGit(work, env, [
      "push",
      "--quiet",
      "origin",
      `HEAD:refs/heads/${branch}`,
    ]);
  }

  const commands: Readonly<Record<string, string>> = {
    nix: `
if [ "$1 $2" = 'build .#flake-lock-summary' ]; then
  mkdir -p "$RUNNER_TEMP/flake-lock-summary/bin"
  cp '${bin}/summary' "$RUNNER_TEMP/flake-lock-summary/bin/flake-lock-summary"
  exit 0
fi
if [ "$1 $2" = 'build .#update-runner' ]; then
  mkdir -p "$RUNNER_TEMP/update-runner/bin"
  cp '${bin}/update-runner' "$RUNNER_TEMP/update-runner/bin/update-runner"
  exit 0
fi
exit 1
`,
    "update-runner": runner,
    // Git prints progress messages that contain temporary paths on stderr.
    // Send them to a file so the job's stderr is deterministic.
    git: `
PATH='${process.env.PATH}' exec git "$@" 2>> '${log}/git-stderr'
`,
    gh: `
if [ "$1 $2" = 'pr view' ]; then
  exit 1
fi
if [ "$1 $2" = 'pr create' ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = '--body-file' ]; then
      cp "$2" '${log}/pr-body'
      break
    fi
    shift
  done
  exit ${options.createStatus ?? 0}
fi
`,
    date: "printf '2026-11-04\\n'",
  };

  for (const [command, script] of Object.entries(commands)) {
    writeFileSync(join(bin, command), `#!${bash}\n${script}`, {
      mode: 0o755,
    });
  }

  try {
    const definition = workflow(filename);
    const contexts = triggerContexts(definition, trigger);
    const update = record(record(definition.jobs).update);
    assert.ok(Array.isArray(update.steps));
    const updateSteps = update.steps.map(record);
    const setup = updateSteps.findIndex(
      (step) => step.name === "Set up secrets access",
    );
    assert.notEqual(setup, -1);
    const script = updateSteps
      .slice(setup + 1)
      .map((step) => {
        const exports = Object.entries(
          step.env === undefined ? {} : record(step.env),
        ).map(
          ([name, value]) =>
            `export ${name}=${quote(interpolate(string(value), contexts))}`,
        );
        return `(\n${[...exports, string(step.run)].join("\n")}\n)`;
      })
      .join(" &&\n");
    const result = spawnSync(bash, ["--noprofile", "--norc", "-c", script], {
      cwd: work,
      encoding: "utf8",
      env: {
        ...env,
        PATH: `${bin}:${process.env.PATH}`,
        RUNNER_TEMP: runnerTemp,
        GITHUB_RUN_ID: "123",
        GITHUB_RUN_ATTEMPT: "2",
        GITHUB_SERVER_URL: "https://github.example.invalid",
        GITHUB_REPOSITORY: "fixture/dotfiles",
        GITHUB_STEP_SUMMARY: join(runnerTemp, "summary.md"),
      },
    });
    const body = join(log, "pr-body");
    const summary = join(runnerTemp, "summary.md");
    return {
      status: result.status,
      stderr: result.stderr,
      body: existsSync(body) ? readFileSync(body, "utf8") : null,
      summary: existsSync(summary) ? readFileSync(summary, "utf8") : null,
      pushed: branches(origin, env),
    };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

const relockSummary = [
  "Automated relock of the flake inputs from the scheduled `flake-update` workflow (`nix flake update`).",
  "",
  "Updated inputs:",
  "",
  "before=before; after=after",
];
const packageSummary = [
  "Automated package bumps from the scheduled `package-update` workflow.",
];
const reportLink =
  "[Full update report](https://github.example.invalid/fixture/dotfiles/actions/runs/123/attempts/2).";
const cupboardFooter = [
  "",
  "After merging, the `cupboard` workflow attempts to build the requested deploy-profile outputs on main and publishes selected outputs and intermediates built during that run to the default cache.",
  "",
];
const bot =
  "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>\n";
const manualRun: Trigger = { event: "workflow_dispatch" };

describe("Scheduled maintenance workflows", () => {
  for (const [filename, prefix, branch, stale, subject] of [
    [
      "flake-update.yml",
      "flake",
      "flake-update/2026-11-04-123-2",
      "flake-update/2026-11-03-122",
      "chore(flake): update inputs",
    ],
    [
      "package-update.yml",
      "pkgs",
      "package-update/2026-11-04-123-2",
      "package-update/2026-11-03",
      "chore(pkgs): update packages",
    ],
  ] as const) {
    it(`${filename} publishes a short PR body and keeps the full report in the job summary`, () => {
      const reportSections = [
        "## Updated\n\n- independent",
        "## Update notices\n\n- teamclaude",
        "## Failed or skipped updates\n\n- nixpkgs",
      ];
      const report =
        [
          reportSections[0],
          `${reportSections[1]}\n  > Review the newer upstream release.`,
          `${reportSections[2]}\n  > ${"Caddy could not refresh. ".repeat(3000)}\n- ${"a".repeat(9000)}`,
        ].join("\n\n") + "\n";
      const run = runUpdateWorkflow(
        filename,
        manualRun,
        `
case "$1" in
  inputs)
    printf 'after\\n' > flake.lock
    ;;
  packages)
    ;;
  *)
    exit 2
    ;;
esac
printf 'locked\\n' > pkgs/fixture/new-lock.json
if [ "$2" = --stage ]; then
  git add -- flake.lock pkgs/fixture/new-lock.json
fi
printf '%s' ${quote(report)}
exit 1
`,
        { "flake.lock": "before\n", "pkgs/fixture/version": "unchanged\n" },
        { branches: [stale] },
      );
      assert.deepEqual(run, {
        status: 0,
        stderr: "",
        body: [
          ...(prefix === "flake" ? relockSummary : packageSummary),
          "",
          reportSections.join("\n\n"),
          "",
          "The summary was shortened.",
          "",
          reportLink,
          ...cupboardFooter,
        ].join("\n"),
        summary: report,
        pushed: {
          [`refs/heads/${branch}`]: {
            author: bot,
            subject: `${subject}\n`,
            files: {
              "flake.lock": prefix === "flake" ? "after\n" : "before\n",
              "pkgs/fixture/version": "unchanged\n",
              "pkgs/fixture/new-lock.json": "locked\n",
            },
          },
        },
      });
    });

    it(`${filename} removes the failed PR branch and preserves the previous branch`, () => {
      const report = "## Updated\n\n- fixture\n";
      const run = runUpdateWorkflow(
        filename,
        manualRun,
        `
printf 'after\\n' > flake.lock
if [ "$2" = --stage ]; then git add -- flake.lock; fi
printf '%s' ${quote(report)}
`,
        { "flake.lock": "before\n" },
        { branches: [stale], createStatus: 42 },
      );
      assert.deepEqual(run, {
        status: 42,
        stderr: "",
        body: [
          ...(prefix === "flake" ? relockSummary : packageSummary),
          "",
          report.trimEnd(),
          "",
          reportLink,
          ...cupboardFooter,
        ].join("\n"),
        summary: report,
        pushed: {
          [`refs/heads/${stale}`]: {
            author: "fixture <fixture@example.invalid>\n",
            subject: "fixture\n",
            files: { "flake.lock": "before\n" },
          },
        },
      });
    });
  }

  it("does not create a PR for a message-only run", () => {
    const run = runUpdateWorkflow(
      "package-update.yml",
      manualRun,
      `
printf '%s\\n' 'Review the newer upstream release.'
`,
      { "flake.lock": "before\n" },
    );
    assert.deepEqual(run, {
      status: 0,
      stderr: "",
      body: null,
      summary: "Review the newer upstream release.\n",
      pushed: {},
    });
  });

  // The Tuesday run and a manual run with the input maintain the lock files.
  const packageUpdate = workflow("package-update.yml");
  const schedules = record(packageUpdate.on).schedule;
  assert.ok(Array.isArray(schedules));
  for (const [trigger, maintained] of [
    ...schedules.map((schedule): [Trigger, boolean] => {
      const cron = string(record(schedule).cron);
      return [
        { event: "schedule", schedule: cron },
        cron.split(" ")[4] === "2",
      ];
    }),
    ...[true, false].map((value): [Trigger, boolean] => [
      { event: "workflow_dispatch", inputs: { "maintain-lockfiles": value } },
      value,
    ]),
  ]) {
    it(`${maintained ? "maintains" : "keeps"} the lock files on ${JSON.stringify(trigger)}`, () => {
      const run = runUpdateWorkflow(
        "package-update.yml",
        trigger,
        `
if [ "$1" != packages ]; then
  exit 2
fi
shift
stage=false
maintain=false
for argument in "$@"; do
  case "$argument" in
    --stage)
      stage=true
      ;;
    --maintain-lockfiles)
      maintain=true
      ;;
    *)
      exit 2
      ;;
  esac
done

printf 'updated\\n' > pkgs/fixture/version
if [ "$maintain" = true ]; then
  printf 'maintained\\n' > pkgs/fixture/pnpm-lock.yaml
fi
if [ "$stage" = true ]; then
  git add -- pkgs
fi
printf '## Updated\\n\\n- fixture\\n'
`,
        {
          "flake.lock": "before\n",
          "pkgs/fixture/version": "old\n",
          "pkgs/fixture/pnpm-lock.yaml": "locked\n",
        },
      );
      assert.deepEqual(run, {
        status: 0,
        stderr: "",
        body: [
          ...packageSummary,
          "",
          "## Updated\n\n- fixture",
          "",
          reportLink,
          ...cupboardFooter,
        ].join("\n"),
        summary: "## Updated\n\n- fixture\n",
        pushed: {
          "refs/heads/package-update/2026-11-04-123-2": {
            author: bot,
            subject: "chore(pkgs): update packages\n",
            files: {
              "flake.lock": "before\n",
              "pkgs/fixture/version": "updated\n",
              "pkgs/fixture/pnpm-lock.yaml": maintained
                ? "maintained\n"
                : "locked\n",
            },
          },
        },
      });
    });
  }
});

describe("Cupboard workflow event admission", () => {
  for (const action of ["opened", "synchronize", "reopened", "closed"]) {
    for (const fork of [false, true]) {
      it(`${action} from ${fork ? "a fork" : "this repository"}`, () => {
        assert.deepEqual(admittedJobs({ name: "pull_request", action, fork }), {
          validation: fork && action !== "closed",
          publish: !fork,
        });
      });
    }
  }

  it("receives the pull-request lifecycle events", () => {
    assert.deepEqual(record(record(caller.on).pull_request).types, [
      "opened",
      "synchronize",
      "reopened",
      "closed",
    ]);
  });

  for (const name of ["push", "workflow_dispatch", "merge_group"]) {
    it(`${name} preserves validation`, () => {
      assert.deepEqual(admittedJobs({ name }), {
        validation: name === "merge_group",
        publish: name !== "merge_group",
      });
    });
  }
});

describe("Cupboard workflow source preparation", () => {
  // The evaluation gate disables import from derivation, so publish inputs
  // that need a build fail instead of building it.
  for (const importsFromDerivation of [false, true]) {
    it(`${importsFromDerivation ? "refuses" : "prepares"} publish inputs ${importsFromDerivation ? "that need" : "without"} an evaluation-time build`, () => {
      const directory = mkdtempSync(join(tmpdir(), "cupboard-inputs-"));
      const output = join(directory, "output");
      writeFileSync(output, "");
      const nix = fakeNix(directory, {
        attributes: {
          ".#.nix.publishInputs": {
            trustedPublicKey: "fixture-key",
            builders: "fixture-builder",
          },
        },
        importsFromDerivation,
      });

      try {
        const result = spawnSync(
          bash,
          ["--noprofile", "--norc", "-c", string(evaluation.run)],
          {
            cwd: directory,
            encoding: "utf8",
            env: {
              ...process.env,
              ...nix,
              PATH: `${directory}:${process.env.PATH}`,
              NIX_CONFIG: "allow-import-from-derivation = true",
              EVENT_NAME: "push",
              EVENT_ACTION: "",
              GITHUB_OUTPUT: output,
            },
          },
        );
        const inputs = importsFromDerivation
          ? ""
          : "trustedPublicKey=fixture-key\nbuilders=fixture-builder\n";
        assert.deepEqual(
          {
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            output: readFileSync(output, "utf8"),
          },
          {
            status: importsFromDerivation ? 1 : 0,
            stdout: inputs,
            stderr: importsFromDerivation
              ? `error: cannot build '${importedDerivation}' during evaluation because the option 'allow-import-from-derivation' is disabled\n`
              : "",
            output: inputs,
          },
        );
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    });
  }

  it("skips fetching and evaluating inputs on close without blocking retirement", () => {
    const directory = mkdtempSync(join(tmpdir(), "cupboard-workflows-"));
    const output = join(directory, "output");
    writeFileSync(output, "");

    try {
      const result = spawnSync(
        bash,
        ["--noprofile", "--norc", "-c", string(evaluation.run)],
        {
          encoding: "utf8",
          env: {
            PATH: "",
            EVENT_NAME: "pull_request",
            EVENT_ACTION: "closed",
            GITHUB_OUTPUT: output,
          },
        },
      );
      assert.deepEqual(
        {
          status: result.status,
          stdout: result.stdout,
          stderr: result.stderr,
          output: readFileSync(output, "utf8"),
          activeActions: steps
            .filter(
              (step) =>
                step.uses !== undefined &&
                allows(step.if, { name: "pull_request", action: "closed" }),
            )
            .map((step) => step.uses),
          publicationDependency: record(record(wrapper.jobs).publish).needs,
        },
        {
          status: 0,
          stdout:
            "::notice::Closed pull request; skipping publish-input evaluation.\n",
          stderr: "",
          output: "",
          activeActions: [],
          publicationDependency: "sources",
        },
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("keeps fetching inputs for ordinary builds", () => {
    const actions = steps.filter((step) => step.uses !== undefined);
    assert.deepEqual(
      ["push", "workflow_dispatch", "pull_request"].map((name) => ({
        name,
        active: actions.map((step) =>
          allows(step.if, { name, action: "opened" }),
        ),
      })),
      [
        { name: "push", active: [true, true] },
        { name: "workflow_dispatch", active: [true, true] },
        { name: "pull_request", active: [true, true] },
      ],
    );
  });
});

describe("Cupboard workflow concurrency", () => {
  it("groups the PR lifecycle independently of branch publication", () => {
    const concurrency = record(caller.concurrency);
    const events: readonly Event[] = [
      {
        name: "pull_request",
        action: "opened",
        number: 17,
        ref: "refs/pull/17/merge",
      },
      {
        name: "pull_request",
        action: "synchronize",
        number: 17,
        ref: "refs/pull/17/merge",
      },
      {
        name: "pull_request",
        action: "closed",
        number: 17,
        ref: "refs/pull/17/merge",
      },
      {
        name: "pull_request",
        action: "closed",
        number: 17,
        ref: "refs/heads/main",
      },
      {
        name: "pull_request",
        action: "reopened",
        number: 17,
        ref: "refs/pull/17/merge",
      },
      {
        name: "pull_request",
        action: "closed",
        number: 18,
        ref: "refs/heads/main",
      },
      { name: "push", ref: "refs/heads/main" },
      { name: "workflow_dispatch", ref: "refs/heads/main" },
    ];

    assert.deepEqual(
      {
        groups: events.map((event) =>
          string(concurrency.group).replace(
            /\$\{\{([\s\S]*?)\}\}/g,
            (_match: string, expression: string) =>
              String(evaluate(expression, event)),
          ),
        ),
        cancelInProgress: events.map((event) =>
          allows(concurrency["cancel-in-progress"], event),
        ),
      },
      {
        groups: [
          "cupboard-17",
          "cupboard-17",
          "cupboard-17",
          "cupboard-17",
          "cupboard-17",
          "cupboard-18",
          "cupboard-refs/heads/main",
          "cupboard-refs/heads/main",
        ],
        cancelInProgress: [true, true, false, false, true, false, false, false],
      },
    );
  });
});

describe("Cupboard merged pull request reuse", () => {
  it("configures merged PR reuse without exposing every PR cache to builders", () => {
    const publication = record(record(wrapper.jobs).publish);
    const inputs = record(publication.with);
    const secrets = record(publication.secrets);

    assert.deepEqual(
      {
        callerPermission: record(record(jobs.publish).permissions)[
          "pull-requests"
        ],
        wrapperPermission: record(publication.permissions)["pull-requests"],
        preset: inputs.preset,
        reuseView: inputs["reuse-view"],
        builderReadsEveryPr: string(secrets.builder_ssh_config).includes(
          "/reuse/",
        ),
      },
      {
        callerPermission: "read",
        wrapperPermission: "read",
        preset: "pull-request-and-branch",
        reuseView: undefined,
        builderReadsEveryPr: false,
      },
    );
  });
});

describe("Cupboard workflow runner read configuration", () => {
  it("rejects evaluation-time builds in both CI configurations", () => {
    const setting = (installable: string): string | undefined =>
      nixConfigurationText(installable)
        .split("\n")
        .find((line) => line.startsWith("allow-import-from-derivation = "));
    const publisher = record(record(record(wrapper.jobs).publish).with);

    assert.deepEqual(
      {
        public: setting(".#nix.ciConfig"),
        publish: setting(string(publisher["nix-config"])),
        sharedCaches: setting(".#nix.substituterConfig"),
        publishCaches: setting(".#nix.publishSubstituterConfig"),
      },
      {
        public: "allow-import-from-derivation = false",
        publish: "allow-import-from-derivation = false",
        sharedCaches: undefined,
        publishCaches: undefined,
      },
    );
  });

  it("separates the publisher's tenant read session from shared-host release caches", () => {
    const inputs = record(record(record(wrapper.jobs).publish).with);
    const tenant = new URL(string(inputs.url));
    const shared = nixConfiguration(".#nix.substituterConfig");
    const publish = nixConfiguration(string(inputs["nix-config"]));
    const readable = shared.substituters.filter((substituter) => {
      const cache = new URL(substituter);
      return (
        cache.hostname !== tenant.hostname ||
        cache.pathname === tenant.pathname ||
        cache.pathname.startsWith(`${tenant.pathname}/`)
      );
    });

    assert.deepEqual(publish, {
      substituters: readable,
      trustedPublicKeys: shared.trustedPublicKeys,
    });
  });
});

function targetFixture(): Record<string, unknown> {
  const file = process.env.CUPBOARD_TARGET_FIXTURE;
  if (file !== undefined) return record(JSON.parse(readFileSync(file, "utf8")));

  const result = spawnSync(
    "nix",
    [
      "eval",
      "--impure",
      "--json",
      "--expr",
      "let flake = builtins.getFlake (toString ./.); in import ./scripts/cupboard-workflows.fixture.nix { lib = flake.inputs.nixpkgs.lib; systems = builtins.attrNames flake.checks; inherit (flake) inputs; }",
    ],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  return record(JSON.parse(result.stdout));
}

interface FixtureTarget {
  readonly attr: string;
  readonly rootSuffix: string;
  readonly rootDrvPath: string;
  readonly system: string;
  readonly bestEffort: boolean;
  readonly cohort: string;
  readonly os: string;
  readonly remote: boolean;
}

function expectedTarget(
  attr: string,
  suffix: string,
  derivation: string,
  system = "x86_64-linux",
  cohort = system,
): FixtureTarget {
  return {
    attr,
    rootSuffix: `${system}/${suffix}`,
    rootDrvPath: `/nix/store/00000000000000000000000000000000-${derivation}.drv`,
    system,
    bestEffort: false,
    cohort,
    os: system.endsWith("-darwin")
      ? "macos-latest"
      : system.startsWith("aarch64-")
        ? "ubuntu-24.04-arm"
        : "ubuntu-latest",
    remote: true,
  };
}

const fixture = targetFixture();
assert.ok(Array.isArray(fixture.checkSystems));
const checkSystems = fixture.checkSystems.map(string);
const validationSystem = string(fixture.validationSystem);

function expectedChecks(
  system: string,
  includePrivate: boolean,
): readonly FixtureTarget[] {
  const checks: readonly (readonly [string, string])[] = includePrivate
    ? [
        ["deploy-activate", "activate"],
        ["deploy-schema", "deploy"],
        ["example", "example"],
        ["falcon-kernel-test", "falcon"],
        ["global", "global"],
        ["host-evaluation-home-test", "host"],
        ["kvm-build", "kvm"],
        ["prompt-conformance-configuration", "configuration"],
        ["vm-test", "vm"],
      ]
    : [
        ["example", "example"],
        ["global", "global"],
        ["kvm-build", "kvm"],
        ["prompt-conformance-configuration", "configuration"],
        ["vm-test", "vm"],
      ];

  return checks
    .filter(
      ([name]) =>
        !["deploy-schema", "global"].includes(name) ||
        system === validationSystem,
    )
    .filter(
      ([name]) =>
        !["kvm-build", "vm-test"].includes(name) || system === "x86_64-linux",
    )
    .map(([name, derivation]) =>
      expectedTarget(
        `.#checks.${system}.${name}`,
        `checks-${name}`,
        derivation,
        system,
        name === "deploy-activate" ? `${system}-deploy` : system,
      ),
    );
}

function expectedPublicTargets(): readonly FixtureTarget[] {
  return [
    expectedTarget(
      ".#packages.x86_64-linux.local-packages",
      "packages",
      "packages",
    ),
    ...checkSystems.flatMap((system) => expectedChecks(system, false)),
    expectedSlowCheckTarget(),
  ];
}

function expectedSlowCheckTarget(): FixtureTarget {
  return expectedTarget(
    `.#legacyPackages.${validationSystem}.slowChecks.example-slow`,
    "slow-checks-example-slow",
    `slow-${validationSystem}`,
    validationSystem,
  );
}

describe("Cupboard strict build ownership", () => {
  it("schedules checks without forcing their derivations or host configurations", () => {
    const namesFor = (system: string): readonly string[] =>
      [
        "assertion-fail",
        "assertion-pass",
        "assertion-unavailable",
        "deploy-activate",
        "deploy-schema",
        "host-evaluation-hermes-managed-config-fixture",
        "host-evaluation-home-fixture",
        `host-evaluation-${system.endsWith("-darwin") ? "darwin" : "nixos"}-fixture`,
        "librechat-bundle-exclusion",
        "librechat-home-manager",
        ...(system.endsWith("-linux") ? ["vm-test"] : []),
      ].sort();
    const selected = [
      ".#deploy.nodes.mac.profiles.system.path",
      ".#deploy.nodes.test.profiles.system.path",
      ".#deploy.nodes.test.profiles.tester.path",
      ".#packages.aarch64-darwin.deploy-rs",
      ".#packages.x86_64-linux.deploy-rs",
      ".#packages.x86_64-linux.local-packages",
      ...checkSystems.flatMap((system) =>
        namesFor(system)
          .filter(
            (name) => name !== "deploy-schema" || system === validationSystem,
          )
          .filter((name) => name !== "vm-test" || system === "x86_64-linux")
          .map((name) => `.#checks.${system}.${name}`),
      ),
      `.#legacyPackages.${validationSystem}.slowChecks.vm-test`,
    ];
    assert.deepEqual(fixture.lazyScheduling, {
      count: selected.length,
      selected,
      checks: Object.fromEntries(
        checkSystems.map((system) => [
          system,
          Object.fromEntries(
            namesFor(system).map((name) => [
              name,
              {
                isDerivation: true,
                runOnce: name === "deploy-schema",
                requiredFeatures:
                  name === "vm-test" ? ["kvm", "nixos-test"] : [],
                drvPathFails: name !== "assertion-pass",
              },
            ]),
          ),
        ]),
      ),
    });
  });

  it("uses one publisher and removes duplicate build workflows", () => {
    assert.deepEqual(
      {
        jobs: Object.keys(jobs),
        publisher: record(jobs.publish).uses,
        targets: record(record(record(wrapper.jobs).publish).with).targets,
        validationPlan: record(jobs.validation).needs,
        validationRunner: record(jobs.validation)["runs-on"],
        validationStrategy: record(jobs.validation).strategy,
        duplicateWorkflows: [
          "prompt-conformance.yml",
          "cupboard-test.yml",
        ].filter((file) => existsSync(join(workflows, file))),
      },
      {
        jobs: ["validation-plan", "validation", "publish"],
        publisher:
          "iainlane/dotfiles/.github/workflows/cupboard-publish.yml@main",
        targets: ".#cupboardOutputs",
        validationPlan: "validation-plan",
        validationRunner: "${{ matrix.os }}",
        validationStrategy: {
          "fail-fast": false,
          matrix: "${{ fromJSON(needs.validation-plan.outputs.matrix) }}",
        },
        duplicateWorkflows: [],
      },
    );
  });

  it("separates deployment closures from packages and other checks", () => {
    const publicTargets = expectedPublicTargets();
    assert.deepEqual(
      { outputs: fixture.outputs, publicOutputs: fixture.publicOutputs },
      {
        publicOutputs: publicTargets,
        outputs: [
          expectedTarget(
            ".#deploy.nodes.mac.profiles.system.path",
            "darwin-mac",
            "system-mac",
            "aarch64-darwin",
            "aarch64-darwin-deploy",
          ),
          expectedTarget(
            ".#deploy.nodes.test.profiles.system.path",
            "nixos-test",
            "system-test",
            "x86_64-linux",
            "x86_64-linux-deploy",
          ),
          expectedTarget(
            ".#deploy.nodes.test.profiles.tester.path",
            "home-test",
            "home-test",
            "x86_64-linux",
            "x86_64-linux-deploy",
          ),
          expectedTarget(
            ".#packages.aarch64-darwin.deploy-rs",
            "deploy-rs",
            "deploy-rs-darwin",
            "aarch64-darwin",
            "aarch64-darwin-deploy",
          ),
          expectedTarget(
            ".#packages.x86_64-linux.deploy-rs",
            "deploy-rs",
            "deploy-rs-linux",
            "x86_64-linux",
            "x86_64-linux-deploy",
          ),
          publicTargets[0],
          ...checkSystems.flatMap((system) => expectedChecks(system, true)),
          expectedSlowCheckTarget(),
        ],
      },
    );
  });

  it("evaluates public targets without reading private profiles or checks", () => {
    assert.deepEqual(
      fixture.publicOutputsWithoutSecrets,
      expectedPublicTargets(),
    );
  });

  for (const importsFromDerivation of [false, true]) {
    it(`${importsFromDerivation ? "refuses a target manifest that needs" : "derives the public build matrix from the target manifest without"} an evaluation-time build`, () => {
      const plan = record(jobs["validation-plan"]);
      assert.ok(Array.isArray(plan.steps));
      const step = plan.steps.map(record).find((step) => step.id === "targets");
      assert.ok(step);
      const directory = mkdtempSync(join(tmpdir(), "cupboard-matrix-"));
      const output = join(directory, "output");
      writeFileSync(output, "");
      const nix = fakeNix(directory, {
        attributes: { ".#.cupboardPublicOutputs": expectedPublicTargets() },
        importsFromDerivation,
      });

      try {
        const result = spawnSync(
          bash,
          ["--noprofile", "--norc", "-c", string(step.run)],
          {
            cwd: directory,
            encoding: "utf8",
            env: {
              ...process.env,
              ...nix,
              PATH: `${directory}:${process.env.PATH}`,
              NIX_CONFIG: "allow-import-from-derivation = true",
              GITHUB_OUTPUT: output,
            },
          },
        );
        const matrix = {
          include: checkSystems.map((system) => ({
            system,
            os: expectedTarget("", "", "", system).os,
          })),
        };

        assert.deepEqual(
          {
            status: result.status,
            stderr: result.stderr,
            output: readFileSync(output, "utf8"),
          },
          importsFromDerivation
            ? {
                status: 1,
                stderr: `error: cannot build '${importedDerivation}' during evaluation because the option 'allow-import-from-derivation' is disabled\n`,
                output: "",
              }
            : {
                status: 0,
                stderr: "",
                output: `matrix=${JSON.stringify(matrix)}\n`,
              },
        );
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    });
  }

  for (const system of checkSystems) {
    it(`builds only the public targets for ${system}`, () => {
      const validation = record(jobs.validation);
      assert.ok(Array.isArray(validation.steps));
      const build = validation.steps
        .map(record)
        .find((step) => step.name === "Build public packages and checks");
      assert.ok(build);
      const directory = mkdtempSync(join(tmpdir(), "cupboard-builds-"));
      const targets = expectedPublicTargets();
      const output = (target: FixtureTarget): string =>
        target.rootDrvPath.replace(/\.drv$/, "");
      const nix = fakeNix(directory, {
        attributes: { ".#.cupboardPublicOutputs": targets },
        outputs: Object.fromEntries(
          targets.map((target) => [target.attr, output(target)]),
        ),
      });
      try {
        const result = spawnSync(
          bash,
          ["--noprofile", "--norc", "-c", string(build.run)],
          {
            encoding: "utf8",
            env: {
              ...process.env,
              ...nix,
              PATH: `${directory}:${process.env.PATH}`,
              RUNNER_TEMP: directory,
              TARGET_SYSTEM: system,
            },
          },
        );
        const index = (name: string): number =>
          Number(/-(\d+)$/.exec(name)?.[1] ?? 0);
        assert.deepEqual(
          {
            status: result.status,
            stderr: result.stderr,
            built: readdirSync(directory)
              .filter((name) => /^strict-build(-\d+)?$/.test(name))
              .sort((left, right) => index(left) - index(right))
              .map((name) => readlinkSync(join(directory, name))),
          },
          {
            status: 0,
            stderr: "",
            built: targets
              .filter((target) => target.system === system)
              .map(output),
          },
        );
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    });
  }
});

describe("Cupboard publication disk cleanup", () => {
  it("prepares runner space and collects after publication", () => {
    const inputs = record(record(record(wrapper.jobs).publish).with);
    assert.deepEqual(
      {
        maximiseSpace: inputs["maximise-space"],
        collectBetweenCohorts: inputs["gc-between-cohorts"],
      },
      { maximiseSpace: true, collectBetweenCohorts: true },
    );
  });
});
