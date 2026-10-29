import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
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

function prepareEvaluation(
  directory: string,
  response: unknown,
): { manifest: string; calls: string } {
  const manifest = join(directory, "response.json");
  const calls = join(directory, "calls");
  writeFileSync(manifest, JSON.stringify(response));
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
    `#!/bin/sh
printf '%s\\n' "$NIX_CONFIG" > "$NIX_CALLS.config"
printf '%s\\n' "$@" > "$NIX_CALLS.args"
cat "$NIX_TARGETS"
`,
    { mode: 0o755 },
  );
  return { manifest, calls };
}

function evaluationCall(calls: string): { args: string[]; config: string } {
  return {
    args: readFileSync(`${calls}.args`, "utf8").trim().split("\n"),
    config: readFileSync(`${calls}.config`, "utf8"),
  };
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

describe("Scheduled flake updates", () => {
  it("opens a PR with the prebuilt summary when the relocked flake cannot evaluate", () => {
    const directory = mkdtempSync(join(tmpdir(), "flake-update-workflow-"));
    const runnerTemp = join(directory, "temp");
    mkdirSync(runnerTemp);
    writeFileSync(join(directory, "flake.lock"), "before\n");
    writeFileSync(
      join(directory, "summary"),
      `#!${bash}
set -euo pipefail
printf 'before=%s; after=%s\\n' "$(cat "$1")" "$(cat "$2")"
`,
      { mode: 0o755 },
    );
    const commands: Readonly<Record<string, string>> = {
      nix: `
printf '%s\\n' "$*" >> nix-calls
if [ -f relocked ]; then
  echo 'The relocked flake cannot evaluate.' >&2
  exit 1
fi
case "$1 $2" in
  'build .#flake-lock-summary')
    mkdir -p "$RUNNER_TEMP/flake-lock-summary/bin"
    cp summary "$RUNNER_TEMP/flake-lock-summary/bin/flake-lock-summary"
    ;;
  'flake update')
    printf 'after\\n' > flake.lock
    touch relocked
    ;;
  *) exit 1 ;;
esac
`,
      git: `
case "$*" in
  'diff --quiet') exit 1 ;;
  'show HEAD:flake.lock') printf 'before\\n' ;;
esac
`,
      gh: `
if [ "$1 $2" = 'pr create' ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = '--body' ]; then
      printf '%s' "$2" > pr-body
      break
    fi
    shift
  done
fi
`,
    };

    for (const [command, script] of Object.entries(commands)) {
      writeFileSync(join(directory, command), `#!${bash}\n${script}`, {
        mode: 0o755,
      });
    }

    try {
      const update = record(record(workflow("flake-update.yml").jobs).update);
      assert.ok(Array.isArray(update.steps));
      const updateSteps = update.steps.map(record);
      const setup = updateSteps.findIndex(
        (step) => step.name === "Set up secrets access",
      );
      assert.notEqual(setup, -1);
      const script = updateSteps
        .slice(setup + 1)
        .map((step) => string(step.run))
        .join("\n");
      const result = spawnSync(bash, ["--noprofile", "--norc", "-c", script], {
        cwd: directory,
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${directory}:${process.env.PATH}`,
          RUNNER_TEMP: runnerTemp,
          GITHUB_RUN_ID: "123",
        },
      });
      const body = join(directory, "pr-body");
      assert.deepEqual(
        {
          status: result.status,
          stderr: result.stderr,
          nixCalls: readFileSync(join(directory, "nix-calls"), "utf8"),
          body: existsSync(body) ? readFileSync(body, "utf8") : null,
        },
        {
          status: 0,
          stderr: "",
          nixCalls: `build .#flake-lock-summary --out-link ${runnerTemp}/flake-lock-summary\nflake update\n`,
          body: [
            "Automated relock of the flake inputs from the scheduled `flake-update` workflow (`nix flake update`).",
            "",
            "Updated inputs:",
            "",
            "before=before; after=after",
            "",
            "After merging, the `cupboard` workflow attempts to build the requested deploy-profile outputs on main and publishes selected outputs and intermediates built during that run to the default cache.",
          ].join("\n"),
        },
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
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
  it("enforces the evaluation policy when preparing publish inputs", () => {
    const directory = mkdtempSync(join(tmpdir(), "cupboard-inputs-"));
    const output = join(directory, "output");
    writeFileSync(output, "");
    const { manifest, calls } = prepareEvaluation(directory, {
      trustedPublicKey: "fixture-key",
      builders: "fixture-builder",
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
            PATH: `${directory}:${process.env.PATH}`,
            NIX_CONFIG: "allow-import-from-derivation = true",
            EVENT_NAME: "push",
            EVENT_ACTION: "",
            GITHUB_OUTPUT: output,
            NIX_TARGETS: manifest,
            NIX_CALLS: calls,
          },
        },
      );
      assert.deepEqual(
        {
          status: result.status,
          stdout: result.stdout,
          stderr: result.stderr,
          output: readFileSync(output, "utf8"),
          evaluation: evaluationCall(calls),
        },
        {
          status: 0,
          stdout: "trustedPublicKey=fixture-key\nbuilders=fixture-builder\n",
          stderr: "",
          output: "trustedPublicKey=fixture-key\nbuilders=fixture-builder\n",
          evaluation: {
            args: [
              "eval",
              "--json",
              ".#nix.publishInputs",
              "--option",
              "allow-import-from-derivation",
              "false",
            ],
            config:
              "allow-import-from-derivation = true\nallow-import-from-derivation = false\n",
          },
        },
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

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

  it("derives the public build matrix from the target manifest", () => {
    const plan = record(jobs["validation-plan"]);
    assert.ok(Array.isArray(plan.steps));
    const step = plan.steps.map(record).find((step) => step.id === "targets");
    assert.ok(step);
    const directory = mkdtempSync(join(tmpdir(), "cupboard-matrix-"));
    const output = join(directory, "output");
    writeFileSync(output, "");
    const { manifest, calls } = prepareEvaluation(
      directory,
      expectedPublicTargets(),
    );

    try {
      const result = spawnSync(
        bash,
        ["--noprofile", "--norc", "-c", string(step.run)],
        {
          cwd: directory,
          encoding: "utf8",
          env: {
            ...process.env,
            PATH: `${directory}:${process.env.PATH}`,
            NIX_CONFIG: "allow-import-from-derivation = true",
            GITHUB_OUTPUT: output,
            NIX_TARGETS: manifest,
            NIX_CALLS: calls,
          },
        },
      );

      assert.deepEqual(
        {
          status: result.status,
          stderr: result.stderr,
          evaluation: evaluationCall(calls),
          matrix: JSON.parse(
            readFileSync(output, "utf8").replace(/^matrix=/, ""),
          ),
        },
        {
          status: 0,
          stderr: "",
          evaluation: {
            args: [
              "eval",
              "--json",
              ".#cupboardPublicOutputs",
              "--option",
              "allow-import-from-derivation",
              "false",
            ],
            config:
              "allow-import-from-derivation = true\nallow-import-from-derivation = false\n",
          },
          matrix: {
            include: checkSystems.map((system) => ({
              system,
              os: expectedTarget("", "", "", system).os,
            })),
          },
        },
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  for (const system of checkSystems) {
    it(`builds only the public targets for ${system}`, () => {
      const validation = record(jobs.validation);
      assert.ok(Array.isArray(validation.steps));
      const build = validation.steps
        .map(record)
        .find((step) => step.name === "Build public packages and checks");
      assert.ok(build);
      const directory = mkdtempSync(join(tmpdir(), "cupboard-builds-"));
      const calls = join(directory, "calls");
      const manifest = join(directory, "targets.json");
      writeFileSync(calls, "");
      writeFileSync(manifest, JSON.stringify(expectedPublicTargets()));
      writeFileSync(
        join(directory, "nix"),
        `#!/bin/sh
printf '%s\n' "$@" '' >> "$NIX_CALLS"
if [ "$1" = eval ]; then
  cat "$NIX_TARGETS"
fi
`,
        { mode: 0o755 },
      );
      try {
        const result = spawnSync(
          bash,
          ["--noprofile", "--norc", "-c", string(build.run)],
          {
            encoding: "utf8",
            env: {
              ...process.env,
              PATH: `${directory}:${process.env.PATH}`,
              RUNNER_TEMP: directory,
              NIX_CALLS: calls,
              NIX_TARGETS: manifest,
              TARGET_SYSTEM: system,
            },
          },
        );
        assert.deepEqual(
          {
            status: result.status,
            stderr: result.stderr,
            calls: readFileSync(calls, "utf8")
              .trim()
              .split("\n\n")
              .map((call) => call.split("\n")),
          },
          {
            status: 0,
            stderr: "",
            calls: [
              ["eval", "--json", ".#cupboardPublicOutputs"],
              [
                "build",
                "--keep-going",
                "--out-link",
                join(directory, "strict-build"),
                ...expectedPublicTargets()
                  .filter((target) => target.system === system)
                  .map((target) => target.attr),
              ],
            ],
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
