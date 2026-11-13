import { afterEach, expect, it, vi } from "vitest";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { ensureSubagentsIdle, subagentPolicy } from "#planning/subagents.ts";

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
  const emit = vi.fn<(event: string, value: unknown) => void>((event, value) =>
    listeners.get(event)?.(value),
  );
  const signal = new AbortController();
  const pending = ensureSubagentsIdle(
    {
      emit,
      on(event, callback) {
        listeners.set(event, callback);
        return () => {
          listeners.delete(event);
        };
      },
    },
    signal.signal,
  );
  const request = emit.mock.calls[0]?.[1];
  if (!Check(requestSchema, request)) {
    throw new Error("The planning status check did not send a request ID.");
  }
  const reply = (value: Record<string, unknown>) =>
    emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      version: 1,
      requestId: request.requestId,
      success: true,
      ...value,
    });
  return {
    pending,
    signal,
    emit,
    listeners,
    reply,
    requestId: request.requestId,
  };
}

function statusRequest(requestId: string) {
  return [
    "subagents:rpc:v1:request",
    {
      version: 1,
      requestId,
      method: "status",
      params: {},
      source: { extension: "planning" },
    },
  ];
}

it("checks the native fleet before approval with no active subagents", async () => {
  const f = fixture();
  f.reply({ requestId: "foreign", data: { fleet: { totalActive: 0 } } });
  f.reply({ data: { fleet: { totalActive: 0 } } });
  await expect(f.pending).resolves.toBeUndefined();
  expect({
    request: f.emit.mock.calls[0],
    listeners: f.listeners.size,
  }).toStrictEqual({ request: statusRequest(f.requestId), listeners: 0 });
});

it.each([1, 3])(
  "refuses approval with %i active subagents",
  async (totalActive) => {
    const f = fixture();
    f.reply({ requestId: "foreign", data: { fleet: { totalActive: 0 } } });
    f.reply({ data: { fleet: { totalActive } } });
    await expect(f.pending).rejects.toStrictEqual(
      new Error(
        "A subagent is still active. Wait for completion or cancel it before requesting implementation approval.",
      ),
    );
    expect({
      request: f.emit.mock.calls[0],
      listeners: f.listeners.size,
    }).toStrictEqual({ request: statusRequest(f.requestId), listeners: 0 });
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
  await expect(f.pending).rejects.toThrow("Cannot verify subagent status");
  expect(f.listeners.size).toBe(0);
});

it("cancels an outstanding status check on human exit", async () => {
  const f = fixture();
  f.signal.abort();
  await expect(f.pending).rejects.toThrow("status check was cancelled");
  expect(f.listeners.size).toBe(0);
});

it("times out when the native status service does not reply", async () => {
  vi.useFakeTimers();
  const f = fixture();
  await Promise.all([
    expect(f.pending).rejects.toStrictEqual(
      new Error(
        "Subagent status is unavailable. Retry before requesting implementation approval.",
      ),
    ),
    vi.advanceTimersByTimeAsync(5000),
  ]);
  expect(f.listeners.size).toBe(0);
});
