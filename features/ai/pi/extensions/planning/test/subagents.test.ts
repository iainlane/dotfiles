import { afterEach, expect, it, vi } from "vitest";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { ensureSubagentsIdle } from "../src/subagents.ts";

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
  const result = pending.then(
    () => ({ allowed: true }),
    (error: unknown) => {
      if (!(error instanceof Error)) {
        throw error;
      }
      return { allowed: false, reason: error.message };
    },
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
    result,
    signal,
    emit,
    listeners,
    reply,
    requestId: request.requestId,
  };
}

it.each([
  { totalActive: 0, expected: { allowed: true } },
  {
    totalActive: 1,
    expected: {
      allowed: false,
      reason:
        "A subagent is still active. Wait for completion or cancel it before requesting implementation approval.",
    },
  },
  {
    totalActive: 3,
    expected: {
      allowed: false,
      reason:
        "A subagent is still active. Wait for completion or cancel it before requesting implementation approval.",
    },
  },
])(
  "checks the native fleet before approval with $totalActive active subagents",
  async ({ totalActive, expected }) => {
    const f = fixture();
    f.reply({ requestId: "foreign", data: { fleet: { totalActive: 0 } } });
    f.reply({ data: { fleet: { totalActive } } });
    await expect(f.result).resolves.toStrictEqual(expected);
    expect({
      request: f.emit.mock.calls[0],
      listeners: f.listeners.size,
    }).toStrictEqual({
      request: [
        "subagents:rpc:v1:request",
        {
          version: 1,
          requestId: f.requestId,
          method: "status",
          params: {},
          source: { extension: "planning" },
        },
      ],
      listeners: 0,
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
  await vi.advanceTimersByTimeAsync(5000);
  await expect(f.result).resolves.toStrictEqual({
    allowed: false,
    reason:
      "Subagent status is unavailable. Retry before requesting implementation approval.",
  });
  expect(f.listeners.size).toBe(0);
});
