import { afterEach, expect, it, vi } from "vitest";
import { Type } from "typebox";
import { Check } from "typebox/value";
import {
  ensureSubagentsIdle,
  SubagentStatusError,
  subagentPolicy,
} from "#planning/subagents.ts";

it.each([undefined, 123, 2_000_000])(
  "preserves the native caller's timeout choice: %s",
  (timeoutMs) => {
    const options = timeoutMs === undefined ? {} : { timeoutMs };
    const input = {
      agent: "planning-explore",
      task: "Inspect the code",
      options,
    };

    expect({
      decision: subagentPolicy({ toolName: "subagent", input }),
      input,
    }).toStrictEqual({
      decision: undefined,
      input: {
        agent: "planning-explore",
        task: "Inspect the code",
        output: false,
        options: {
          ...options,
          context: "fresh",
          artifacts: false,
          mission: false,
        },
      },
    });
  },
);

const requestSchema = Type.Object({ requestId: Type.String() });
afterEach(() => vi.useRealTimers());

function fixture() {
  const listeners = new Map<string, (value: unknown) => void>();
  // The native subagent service receives the status requests and leaves them
  // for the test to answer.
  const requests: unknown[] = [];
  listeners.set("subagents:rpc:v1:request", (value) => {
    requests.push(value);
  });
  const events = {
    emit: (event: string, value: unknown) => listeners.get(event)?.(value),
    on(event: string, callback: (value: unknown) => void) {
      listeners.set(event, callback);
      return () => {
        listeners.delete(event);
      };
    },
  };
  const signal = new AbortController();
  const pending = ensureSubagentsIdle(events, signal.signal);
  const request = requests[0];
  if (!Check(requestSchema, request)) {
    throw new Error("The planning status check did not send a request ID.");
  }
  const reply = (value: Record<string, unknown>) =>
    events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      version: 1,
      requestId: request.requestId,
      success: true,
      ...value,
    });
  return {
    pending,
    signal,
    requests,
    listeners: () => [...listeners.keys()],
    reply,
    requestId: request.requestId,
  };
}

function statusRequest(requestId: string) {
  return {
    version: 1,
    requestId,
    method: "status",
    params: {},
    source: { extension: "planning" },
  };
}

it("checks the native fleet before approval with no active subagents", async () => {
  const f = fixture();
  f.reply({ requestId: "foreign", data: { fleet: { totalActive: 0 } } });
  f.reply({ data: { fleet: { totalActive: 0 } } });
  await expect(f.pending).resolves.toBeUndefined();
  expect({
    requests: f.requests,
    listeners: f.listeners(),
  }).toStrictEqual({
    requests: [statusRequest(f.requestId)],
    listeners: ["subagents:rpc:v1:request"],
  });
});

it.each([1, 3])(
  "refuses approval with %i active subagents",
  async (totalActive) => {
    const f = fixture();
    f.reply({ requestId: "foreign", data: { fleet: { totalActive: 0 } } });
    f.reply({ data: { fleet: { totalActive } } });
    await expect(f.pending).rejects.toStrictEqual(
      new SubagentStatusError("active"),
    );
    expect({
      requests: f.requests,
      listeners: f.listeners(),
    }).toStrictEqual({
      requests: [statusRequest(f.requestId)],
      listeners: ["subagents:rpc:v1:request"],
    });
  },
);

it.each([
  {
    success: false,
    error: { code: "no_active_session", message: "Unavailable" },
  },
  { data: { fleet: { totalActive: -1 } } },
  { data: {} },
])("refuses approval without a valid native status: %j", async (reply) => {
  const f = fixture();
  f.reply(reply);
  await expect(f.pending).rejects.toStrictEqual(
    new SubagentStatusError("unverified"),
  );
  expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
});

it("cancels an outstanding status check on human exit", async () => {
  const f = fixture();
  const exit = new Error("Fixture human exit");
  f.signal.abort(exit);
  await expect(f.pending).rejects.toStrictEqual(
    new SubagentStatusError("cancelled", { cause: exit }),
  );
  expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
});

it("times out when the native status service does not reply", async () => {
  vi.useFakeTimers();
  const f = fixture();
  await Promise.all([
    expect(f.pending).rejects.toStrictEqual(
      new SubagentStatusError("unavailable"),
    ),
    vi.advanceTimersByTimeAsync(5000),
  ]);
  expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
});
