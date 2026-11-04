import { expect, it } from "vitest";
import { readTasks, taskSummary, readAgents } from "../src/workflow.ts";
import { Diagnostics } from "../src/diagnostics.ts";

const entry = (tasks: unknown[]) => ({
  type: "message",
  message: {
    role: "toolResult",
    toolName: "todo",
    details: { tasks, nextId: 5 },
  },
});

it("uses the latest persisted complete task snapshot", () => {
  const tasks = readTasks([
    entry([{ id: 1, subject: "old", status: "pending" }]),
    entry([
      { id: 1, subject: "done", status: "completed" },
      {
        id: 2,
        subject: "working",
        activeForm: "writing tests",
        status: "in_progress",
      },
      { id: 3, subject: "blocked", status: "pending", blockedBy: [2] },
      { id: 4, subject: "deleted", status: "deleted" },
    ]),
  ]);

  expect(taskSummary(tasks)).toStrictEqual({
    completed: 1,
    total: 3,
    running: 1,
    blocked: 1,
    current: "writing tests",
  });
  expect(taskSummary(readTasks([entry([])]))).toStrictEqual({
    completed: 0,
    total: 0,
    running: 0,
    blocked: 0,
    current: undefined,
  });
});

it("does not count completed or deleted dependencies as blocking", () => {
  expect(
    taskSummary(
      readTasks([
        entry([
          { id: 1, subject: "done", status: "completed" },
          { id: 2, subject: "gone", status: "deleted" },
          { id: 3, subject: "ready", status: "pending", blockedBy: [1, 2] },
        ]),
      ]),
    ),
  ).toStrictEqual({
    completed: 1,
    total: 2,
    running: 0,
    blocked: 0,
    current: undefined,
  });
});

it("uses exact fleet totals and counts top-level run failures without double counting", () => {
  expect(
    readAgents({
      fleet: { version: 1, totalActive: 19, omitted: 3, entries: [] },
      asyncSnapshot: {
        kind: "pi-subagents.async-status-snapshot",
        version: 1,
        omitted: { runs: 1, children: 2, byteLimitExceeded: false },
        runs: [
          {
            id: "a",
            label: "review",
            state: "failed",
            children: [{ state: "failed" }],
          },
          { id: "b", label: "paused", state: "paused" },
        ],
      },
    }),
  ).toStrictEqual({
    active: 19,
    failed: 1,
    paused: 1,
    incomplete: true,
    runs: [
      { label: "review", state: "failed" },
      { label: "paused", state: "paused" },
    ],
    stale: false,
  });
  expect(readAgents({ fleet: { totalActive: 0 } })).toBeUndefined();
});

it("replaces diagnostics per file, honours sequence and marks touched data provisional", () => {
  const diagnostics = new Diagnostics("/work");

  const publish = (seq: number, items: unknown[], truncated = false) => {
    diagnostics.receive({
      v: 1,
      cwd: "/work",
      seq,
      ts: 1,
      files: [{ path: "/work/a.ts", diagnostics: items, truncated }],
    });
  };

  expect(diagnostics.summary()).toStrictEqual({
    errors: 0,
    warnings: 0,
    pending: 0,
    truncated: false,
    observed: false,
  });

  publish(2, [{ severity: "error", message: "bad" }], true);
  publish(1, []);
  diagnostics.touch({ v: 1, cwd: "/work", paths: ["/work/a.ts"] });

  expect(diagnostics.summary()).toStrictEqual({
    errors: 1,
    warnings: 0,
    pending: 1,
    truncated: true,
    observed: true,
  });

  publish(3, []);

  expect(diagnostics.summary()).toStrictEqual({
    errors: 0,
    warnings: 0,
    pending: 0,
    truncated: false,
    observed: true,
  });
});
