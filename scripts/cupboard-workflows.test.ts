import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { runInNewContext } from "node:vm";

const workflows = process.env.CUPBOARD_WORKFLOWS ?? ".github/workflows";

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
    ".#nix.publishSubstituterConfig": process.env.CUPBOARD_PUBLISH_NIX_CONFIG,
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
  it("skips fetching and evaluating inputs on close without blocking retirement", () => {
    const directory = mkdtempSync(join(tmpdir(), "cupboard-workflows-"));
    const output = join(directory, "output");
    writeFileSync(output, "");

    try {
      const result = spawnSync(
        process.env.CUPBOARD_WORKFLOWS_BASH ?? "/bin/bash",
        ["-c", string(evaluation.run)],
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
  it("selects the trusted wrapper without exposing every PR cache to builders", () => {
    const publication = record(record(wrapper.jobs).publish);
    const inputs = record(publication.with);
    const secrets = record(publication.secrets);

    assert.deepEqual(
      {
        workflow: publication.uses,
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
        workflow:
          "underwhelmingperformance/cupboard/.github/workflows/cupboard-flake-publish-trusted.yml@v0.0.45",
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
      "let flake = builtins.getFlake (toString ./.); in import ./scripts/cupboard-workflows.fixture.nix { lib = flake.inputs.nixpkgs.lib; systems = builtins.attrNames flake.checks; }",
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
): FixtureTarget {
  return {
    attr,
    rootSuffix: `${system}/${suffix}`,
    rootDrvPath: `/nix/store/00000000000000000000000000000000-${derivation}.drv`,
    system,
    bestEffort: false,
    cohort: system,
    os: system.endsWith("-darwin")
      ? "macos-latest"
      : system.startsWith("aarch64-")
        ? "ubuntu-24.04-arm"
        : "ubuntu-latest",
    remote: !system.endsWith("-darwin"),
  };
}

const fixture = targetFixture();
assert.ok(Array.isArray(fixture.checkSystems));
const checkSystems = fixture.checkSystems.map(string);

function expectedChecks(
  system: string,
  includePrivate: boolean,
): readonly FixtureTarget[] {
  const checks: readonly (readonly [string, string])[] = includePrivate
    ? [
        ["deploy-schema", "deploy"],
        ["example", "example"],
        ["falcon-kernel-test", "falcon"],
        ["host-evaluation-home-test", "host"],
        ["prompt-conformance-configuration", "configuration"],
      ]
    : [
        ["example", "example"],
        ["prompt-conformance-configuration", "configuration"],
      ];

  return checks.map(([name, derivation]) =>
    expectedTarget(
      `.#checks.${system}.${name}`,
      `checks-${name}`,
      derivation,
      system,
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
    ...[
      "claudeEndpoint",
      "codexEndpoint",
      "codexProtocol",
      "fixtureEnvironments",
      "python",
    ].map((name) =>
      expectedTarget(
        `.#packages.x86_64-linux.claude-prompt-conformance.tests.${name}`,
        `prompt-conformance-${name}`,
        name,
      ),
    ),
  ];
}

describe("Cupboard strict build ownership", () => {
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

  it("groups hosts, packages and all checks into strict system cohorts", () => {
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
          ),
          expectedTarget(
            ".#deploy.nodes.test.profiles.system.path",
            "nixos-test",
            "system-test",
          ),
          expectedTarget(
            ".#deploy.nodes.mac.profiles.tester.path",
            "home-mac",
            "home-mac",
            "aarch64-darwin",
          ),
          expectedTarget(
            ".#deploy.nodes.test.profiles.tester.path",
            "home-test",
            "home-test",
          ),
          expectedTarget(
            ".#packages.aarch64-darwin.deploy-rs",
            "deploy-rs",
            "deploy-rs-darwin",
            "aarch64-darwin",
          ),
          expectedTarget(
            ".#packages.x86_64-linux.deploy-rs",
            "deploy-rs",
            "deploy-rs-linux",
          ),
          publicTargets[0],
          ...checkSystems.flatMap((system) => expectedChecks(system, true)),
          ...publicTargets.slice(1 + checkSystems.length * 2),
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
    const manifest = join(directory, "targets.json");
    writeFileSync(output, "");
    writeFileSync(manifest, JSON.stringify(expectedPublicTargets()));
    writeFileSync(join(directory, "nix"), '#!/bin/sh\ncat "$NIX_TARGETS"\n', {
      mode: 0o755,
    });

    try {
      const result = spawnSync(
        process.env.CUPBOARD_WORKFLOWS_BASH ?? "/bin/bash",
        ["-c", string(step.run)],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            PATH: `${directory}:${process.env.PATH}`,
            GITHUB_OUTPUT: output,
            NIX_TARGETS: manifest,
          },
        },
      );

      assert.deepEqual(
        {
          status: result.status,
          stderr: result.stderr,
          matrix: JSON.parse(
            readFileSync(output, "utf8").replace(/^matrix=/, ""),
          ),
        },
        {
          status: 0,
          stderr: "",
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
          process.env.CUPBOARD_WORKFLOWS_BASH ?? "/bin/bash",
          ["-c", string(build.run)],
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
