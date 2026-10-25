import { expect, it, vi } from "vitest";
import {
  SUBAGENT_DELEGATION_CANCEL_EVENT,
  SUBAGENT_DELEGATION_REQUEST_EVENT,
  SUBAGENT_DELEGATION_RESPONSE_EVENT,
  SUBAGENT_DELEGATION_UPDATE_EVENT,
} from "pi-subagents/delegation";
import {
  research,
  type ResearchTransport,
  type ResearchUpdate,
} from "../src/delegation.ts";

function fixture() {
  const listeners = new Map<string, (value: unknown) => void>();
  const timers = new Map<() => void, number>();
  const emit = vi.fn<ResearchTransport["events"]["emit"]>();
  let id = 0;
  const transport: ResearchTransport = {
    events: {
      emit,
      on(event, callback) {
        listeners.set(event, callback);
        return () => {
          listeners.delete(event);
        };
      },
    },
    requestId: () => `id-${++id}`,
    after(milliseconds, callback) {
      timers.set(callback, milliseconds);
      return () => {
        timers.delete(callback);
      };
    },
  };
  const update = vi.fn<(value: ResearchUpdate) => void>();
  const pending = research(
    transport,
    {
      ownerRunId: "session",
      agent: "planning-explore",
      task: "Inspect the implementation",
      cwd: "/work",
      timeoutMs: 100,
    },
    new AbortController().signal,
    update,
  );
  const identity = { requestId: "id-1", nodeId: "id-2", ownerRunId: "session" };
  return { listeners, timers, emit, update, pending, identity };
}

it("projects correlated research data without trusting unconsumed protocol fields", async () => {
  const f = fixture();
  f.listeners.get(SUBAGENT_DELEGATION_RESPONSE_EVENT)?.({
    ...f.identity,
    nodeId: "foreign",
    status: "completed",
  });
  f.listeners.get(SUBAGENT_DELEGATION_UPDATE_EVENT)?.({
    ...f.identity,
    recentOutput: 42,
    currentTool: "read",
  });
  f.listeners.get(SUBAGENT_DELEGATION_RESPONSE_EVENT)?.({
    ...f.identity,
    status: "completed",
    runId: "run",
    error: "",
    result: { kind: "text", text: "Findings" },
    usage: { tokens: 12 },
  });
  expect({
    result: await f.pending,
    updates: f.update.mock.calls,
    timers: f.timers.size,
    listeners: f.listeners.size,
  }).toStrictEqual({
    result: {
      status: "completed",
      runId: "run",
      error: "",
      result: { kind: "text", text: "Findings" },
      usage: { tokens: 12 },
    },
    updates: [],
    timers: 0,
    listeners: 0,
  });
});

it("cancels timed out research and removes its timer and listeners", async () => {
  const f = fixture();
  expect([...f.timers.values()]).toStrictEqual([5100]);
  for (const expire of f.timers.keys()) {
    expire();
  }
  await expect(f.pending).rejects.toThrow("Planning research timed out");
  expect({
    events: f.emit.mock.calls.map(([event]) => event),
    timers: f.timers.size,
    listeners: f.listeners.size,
  }).toStrictEqual({
    events: [
      SUBAGENT_DELEGATION_REQUEST_EVENT,
      SUBAGENT_DELEGATION_CANCEL_EVENT,
    ],
    timers: 0,
    listeners: 0,
  });
});

it.each([
  { status: "completed", runId: 17 },
  { status: "completed", result: { kind: "text", text: 42 } },
  { status: "unknown-status" },
])("rejects a malformed correlated response: %j", async (payload) => {
  const f = fixture();
  f.listeners.get(SUBAGENT_DELEGATION_RESPONSE_EVENT)?.({
    ...f.identity,
    ...payload,
  });
  await expect(f.pending).rejects.toThrow("Invalid planning research response");
  expect({ timers: f.timers.size, listeners: f.listeners.size }).toStrictEqual({
    timers: 0,
    listeners: 0,
  });
});
