import { afterEach, expect, it, vi } from "vitest";
import { RpcClient } from "../src/rpc.ts";

function harness() {
  const handlers = new Map<string, (value: unknown) => void>();
  const bus = {
    on(key: string, handler: (value: unknown) => void) {
      handlers.set(key, handler);

      return () => {
        handlers.delete(key);
      };
    },
    emit: vi.fn<(event: string, value: unknown) => void>(),
  };

  return { bus, handlers, client: new RpcClient(bus) };
}

afterEach(() => vi.useRealTimers());

it.each([
  {
    success: false,
    error: { code: "UNAVAILABLE", message: "Collector unavailable" },
    expected: { kind: "remote", message: "UNAVAILABLE: Collector unavailable" },
  },
  {
    success: "invalid",
    expected: { kind: "malformed", message: "Invalid RPC reply" },
  },
])(
  "reports a $expected.kind reply and removes the subscription",
  async ({ expected, ...payload }) => {
    vi.useFakeTimers();

    const { bus, handlers, client } = harness();
    const result = client.request("status");
    const request = bus.emit.mock.lastCall?.[1];

    if (!request || typeof request !== "object" || !("requestId" in request))
      throw new Error("Expected an RPC request");

    handlers.get(`subagents:rpc:v1:reply:${request.requestId}`)?.({
      version: 1,
      requestId: request.requestId,
      ...payload,
    });

    expect({
      result: await result,
      subscriptions: handlers.size,
      timers: vi.getTimerCount(),
    }).toStrictEqual({
      result: { ok: false, error: expected },
      subscriptions: 0,
      timers: 0,
    });

    client.dispose();
  },
);

it("reports transport failure without leaving a timer or subscription", async () => {
  vi.useFakeTimers();

  const { bus, handlers, client } = harness();

  bus.emit.mockImplementation(() => {
    throw new Error("Bus unavailable\nretry later");
  });

  const result = await client.request("status");

  expect({
    result,
    subscriptions: handlers.size,
    timers: vi.getTimerCount(),
  }).toStrictEqual({
    result: {
      ok: false,
      error: { kind: "transport", message: "Bus unavailable retry later" },
    },
    subscriptions: 0,
    timers: 0,
  });
});
