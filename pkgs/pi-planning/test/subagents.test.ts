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

afterEach(() => vi.useRealTimers());

type Listener = (value: unknown) => void;

class EventBus {
  readonly listeners = new Map<string, Listener>();

  emit(event: string, value: unknown): void {
    this.listeners.get(event)?.(value);
  }

  on(event: string, callback: Listener): () => void {
    this.listeners.set(event, callback);
    return () => {
      this.listeners.delete(event);
    };
  }
}

const statusRequestSchema = Type.Object({
  version: Type.Literal(1),
  requestId: Type.String({ minLength: 1 }),
  method: Type.Literal("status"),
  params: Type.Object({}, { additionalProperties: false }),
  source: Type.Object({ extension: Type.Literal("planning") }),
});

/**
 * The native subagent service on the event bus. It answers a well-formed
 * planning status request with `status` or `failure`, and any other request
 * with an `invalid_request` error. When `strayStatus` is set, a reply for
 * another client's request arrives on the same channel first.
 */
class SubagentService {
  status: unknown = { fleet: { totalActive: 0 } };
  failure: { code: string; message: string } | undefined;
  strayStatus: unknown;
  replying = true;
  private readonly events: EventBus;

  constructor(events: EventBus) {
    this.events = events;
    events.on("subagents:rpc:v1:request", (request) => {
      this.handle(request);
    });
  }

  private handle(request: unknown): void {
    if (!this.replying) {
      return;
    }
    const requestId =
      typeof request === "object" &&
      request !== null &&
      "requestId" in request &&
      typeof request.requestId === "string"
        ? request.requestId
        : "unknown";
    const channel = `subagents:rpc:v1:reply:${requestId}`;
    if (this.strayStatus !== undefined) {
      this.events.emit(channel, {
        version: 1,
        requestId: "another-client",
        success: true,
        data: this.strayStatus,
      });
    }
    if (!Check(statusRequestSchema, request)) {
      this.events.emit(channel, {
        version: 1,
        requestId,
        success: false,
        error: {
          code: "invalid_request",
          message: "Unsupported status request.",
        },
      });
      return;
    }
    this.events.emit(
      channel,
      this.failure === undefined
        ? { version: 1, requestId, success: true, data: this.status }
        : { version: 1, requestId, success: false, error: this.failure },
    );
  }
}

function fixture(configure: (service: SubagentService) => void = () => {}) {
  const events = new EventBus();
  const service = new SubagentService(events);
  configure(service);
  const signal = new AbortController();
  return {
    pending: ensureSubagentsIdle(events, signal.signal),
    signal,
    listeners: () => [...events.listeners.keys()],
  };
}

it("checks the native fleet before approval with no active subagents", async () => {
  const f = fixture((service) => {
    service.strayStatus = { fleet: { totalActive: 1 } };
  });
  await expect(f.pending).resolves.toBeUndefined();
  expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
});

it.each([1, 3])(
  "refuses approval with %i active subagents",
  async (totalActive) => {
    const f = fixture((service) => {
      service.strayStatus = { fleet: { totalActive: 0 } };
      service.status = { fleet: { totalActive } };
    });
    await expect(f.pending).rejects.toStrictEqual(
      new SubagentStatusError("active"),
    );
    expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
  },
);

it.each([
  {
    description: "a service error",
    configure: (service: SubagentService) => {
      service.failure = { code: "no_active_session", message: "Unavailable" };
    },
  },
  {
    description: "a negative count",
    configure: (service: SubagentService) => {
      service.status = { fleet: { totalActive: -1 } };
    },
  },
  {
    description: "a status without a fleet",
    configure: (service: SubagentService) => {
      service.status = {};
    },
  },
])(
  "refuses approval without a valid native status: $description",
  async ({ configure }) => {
    const f = fixture(configure);
    await expect(f.pending).rejects.toStrictEqual(
      new SubagentStatusError("unverified"),
    );
    expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
  },
);

it("cancels an outstanding status check on human exit", async () => {
  const f = fixture((service) => {
    service.replying = false;
  });
  const exit = new Error("Fixture human exit");
  f.signal.abort(exit);
  await expect(f.pending).rejects.toStrictEqual(
    new SubagentStatusError("cancelled", { cause: exit }),
  );
  expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
});

it("times out when the native status service does not reply", async () => {
  vi.useFakeTimers();
  const f = fixture((service) => {
    service.replying = false;
  });
  await Promise.all([
    expect(f.pending).rejects.toStrictEqual(
      new SubagentStatusError("unavailable"),
    ),
    vi.advanceTimersByTimeAsync(5000),
  ]);
  expect(f.listeners()).toStrictEqual(["subagents:rpc:v1:request"]);
});
