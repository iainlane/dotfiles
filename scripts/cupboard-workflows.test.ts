import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
  return Object.fromEntries(
    ["configuration-validation", "packages", "publish"].map((name) => [
      name,
      allows(record(jobs[name]).if, event),
    ]),
  );
}

describe("Cupboard workflow event admission", () => {
  for (const action of ["opened", "synchronize", "reopened", "closed"]) {
    for (const fork of [false, true]) {
      it(`${action} from ${fork ? "a fork" : "this repository"}`, () => {
        assert.deepEqual(admittedJobs({ name: "pull_request", action, fork }), {
          "configuration-validation": action !== "closed",
          packages: action !== "closed",
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
        "configuration-validation": true,
        packages: true,
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
