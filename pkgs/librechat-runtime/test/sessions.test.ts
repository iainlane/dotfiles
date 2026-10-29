import {
  ConversationPrincipalError,
  RuntimeNotRegisteredError,
  ConversationIdError,
  SessionBusyError,
  SessionClosingError,
} from "../src/errors.ts";
import { beforeEach, expect, it } from "vitest";
import {
  SessionManager,
  type GuestBackend,
  type Session,
  type SessionStore,
} from "../src/sessions.ts";
import { runtimeIdentity } from "../src/identity.ts";

const userId = "0123456789abcdef01234567";

const conversationId = "ea277865-9bbd-45ec-9cd2-234cf9dc9169";

let records: Map<string, Session>;

let store: SessionStore;

let clock = 0;

let events: string[];

let failCheckpoint: boolean;

const backend: GuestBackend = {
  async start(session, restore) {
    events.push(restore ? "restore" : "start");

    return {
      socket: `/private/${session.runtimeId}.sock`,
      bootId: "test-boot",
    };
  },
  async checkpoint() {
    events.push("checkpoint");

    if (failCheckpoint) {
      throw new CheckpointInterruptedError();
    }
  },
  async stop() {
    events.push("stop");
  },
  async remove() {
    events.push("remove");
  },
};

beforeEach(() => {
  records = new Map();

  store = {
    load: async (id) => structuredClone(records.get(id)),
    save: async (session) => {
      records.set(session.runtimeId, structuredClone(session));
    },
    list: async () => [...records.keys()],
  };

  clock = 0;

  events = [];

  failCheckpoint = false;
});

function manager(guestBackend: GuestBackend = backend): SessionManager {
  return new SessionManager({
    store,
    userId,
    idleMs: 100,
    retentionMs: 1000,
    backend: guestBackend,
    now: () => clock,
  });
}

class LeaseSaveError extends Error {
  constructor() {
    super("The session lease could not be saved");

    this.name = "LeaseSaveError";
  }
}

it("rejects queued conversation registration after shutdown starts", async () => {
  const sessions = manager();

  const registration = sessions.register(userId, conversationId);
  const shutdown = sessions.shutdown();

  await expect(registration).rejects.toThrow(SessionClosingError);

  await shutdown;

  expect({ events, records: [...records] }).toStrictEqual({
    events: [],
    records: [],
  });
});

it("drains a guest after saving a new lease fails", async () => {
  const sessions = manager();

  const active = await sessions.register(userId, conversationId);

  const save = store.save.bind(store);

  store.save = async () => {
    throw new LeaseSaveError();
  };

  await expect(sessions.acquire(active.runtimeId)).rejects.toThrow(
    LeaseSaveError,
  );

  store.save = save;

  clock = 101;

  await sessions.sweep();

  await sessions.shutdown();

  expect(events).toStrictEqual(["start", "checkpoint", "stop"]);
});

it("rejects other principals and unregistered runtime identities", async () => {
  const sessions = manager();

  await expect(
    sessions.register("another-user", conversationId),
  ).rejects.toThrow(ConversationPrincipalError);

  await expect(
    sessions.acquire("rt_0000000000000000000000000000000000000000"),
  ).rejects.toThrow(RuntimeNotRegisteredError);

  expect(events).toStrictEqual([]);
});

it("uses one VM for concurrent CodeAPI and MCP leases", async () => {
  const sessions = manager();

  const session = await sessions.register(userId, conversationId);

  const [code, mcp] = await Promise.all([
    sessions.acquire(session.runtimeId),
    sessions.acquire(session.runtimeId),
  ]);

  clock = 200;

  await sessions.sweep();

  expect({ code: code.guest, mcp: mcp.guest, events }).toStrictEqual({
    code: { socket: `/private/${session.runtimeId}.sock`, bootId: "test-boot" },
    mcp: { socket: `/private/${session.runtimeId}.sock`, bootId: "test-boot" },
    events: ["start"],
  });

  await Promise.all([code.release(), mcp.release()]);
});

it("checkpoints before idle stop and restores before reuse", async () => {
  const sessions = manager();

  const original = await sessions.register(userId, conversationId);

  const lease = await sessions.acquire(original.runtimeId);
  await lease.release();

  clock = 101;

  await sessions.sweep();

  const resumed = await sessions.register(userId, conversationId);
  const resumedLease = await sessions.acquire(resumed.runtimeId);
  await resumedLease.release();

  expect({
    runtime: resumed.runtimeId,
    generation: resumed.generation,
    originalGeneration: original.generation,
    events,
  }).toStrictEqual({
    runtime: original.runtimeId,
    generation: 1,
    originalGeneration: 1,
    events: ["start", "checkpoint", "stop", "restore"],
  });
});

it("keeps a VM running when checkpointing fails", async () => {
  const sessions = manager();

  const original = await sessions.register(userId, conversationId);

  const lease = await sessions.acquire(original.runtimeId);
  await lease.release();

  failCheckpoint = true;

  clock = 101;

  await expect(sessions.sweep()).rejects.toThrow(CheckpointInterruptedError);

  const resumed = await sessions.acquire(original.runtimeId);

  expect(events).toStrictEqual(["start", "checkpoint"]);

  await resumed.release();
});

it("extends retention on conversation activity and deletes expired work", async () => {
  const sessions = manager();

  const session = await sessions.register(userId, conversationId);
  const lease = await sessions.acquire(session.runtimeId);
  await lease.release();

  clock = 900;

  await sessions.register(userId, conversationId);

  clock = 1500;

  await sessions.sweep();

  clock = 1901;

  await sessions.sweep();

  const recreated = await sessions.register(userId, conversationId);

  expect({
    generation: recreated.generation,
    reset: recreated.resetReason,
    events,
  }).toStrictEqual({
    generation: 2,
    reset:
      "The previous workspace expired and was deleted, including unpushed work.",
    events: ["start", "checkpoint", "stop", "remove"],
  });
});

it("recovers durable registration and reports a controller restart", async () => {
  const first = manager();

  const original = await first.register(userId, conversationId);
  const lease = await first.acquire(original.runtimeId);
  await lease.release();

  clock = 101;

  await first.sweep();

  const second = manager();

  const resumed = await second.register(userId, conversationId);
  const resumedLease = await second.acquire(resumed.runtimeId);
  await resumedLease.release();

  const state = records.get(original.runtimeId);

  expect({
    runtime: resumed.runtimeId,
    generation: resumed.generation,
    events,
    saved: typeof state === "object",
  }).toStrictEqual({
    runtime: original.runtimeId,
    generation: 1,
    events: ["start", "checkpoint", "stop", "restore"],
    saved: true,
  });
});

it("does not derive host paths from conversation IDs", async () => {
  const sessions = manager();

  await expect(sessions.register(userId, "../../outside")).rejects.toThrow(
    ConversationIdError,
  );

  expect(events).toStrictEqual([]);
});

it("matches the pinned upstream runtime identity vector", () => {
  expect(runtimeIdentity(userId, conversationId)).toBe(
    "rt_b23091dbc7e7f95d8a898089d1fb2d0ca0562f55",
  );
});

it("drains active calls before shutdown and refuses new calls", async () => {
  const sessions = manager();

  const session = await sessions.register(userId, conversationId);

  const lease = await sessions.acquire(session.runtimeId);

  await expect(sessions.shutdown()).rejects.toThrow(SessionBusyError);

  await expect(sessions.acquire(session.runtimeId)).rejects.toThrow(
    SessionClosingError,
  );

  await lease.release();

  await sessions.shutdown();

  expect(events).toStrictEqual(["start", "checkpoint", "stop"]);
});

it("resets an idle workspace and reports discarded work", async () => {
  const sessions = manager();

  const original = await sessions.register(userId, conversationId);

  const lease = await sessions.acquire(original.runtimeId);
  await lease.release();

  await sessions.reset(original.runtimeId);

  const session = await sessions.register(userId, conversationId);

  expect({
    generation: session.generation,
    events,
    reason: session.resetReason,
  }).toStrictEqual({
    generation: 2,
    events: ["start", "stop", "remove"],
    reason:
      "The workspace was explicitly reset and unpushed work was discarded.",
  });
});

it("binds a later conversation hook to the VM already acquired by authenticated prewarming", async () => {
  const sessions = manager();

  const id = runtimeIdentity(userId, conversationId);

  const prewarm = await sessions.acquireCodeRuntime(id);

  await prewarm.release();

  const registered = await sessions.register(userId, conversationId);

  const mcp = await sessions.acquire(id);

  expect({
    conversation: registered.conversationId,
    guest: mcp.guest,
    events,
  }).toStrictEqual({
    conversation: conversationId,
    guest: prewarm.guest,
    events: ["start"],
  });

  await mcp.release();
});

class CheckpointInterruptedError extends Error {
  constructor() {
    super("Checkpoint interrupted");

    this.name = "CheckpointInterruptedError";
  }
}

it("skips a cancelled CodeAPI acquisition queued behind another VM startup", async () => {
  const started = Promise.withResolvers<void>();

  const proceed = Promise.withResolvers<void>();

  const sessions = manager({
    ...backend,
    start: async (session, restore) => {
      started.resolve();

      await proceed.promise;

      return await backend.start(session, restore);
    },
  });

  const registration = await sessions.register(userId, conversationId);
  const active = sessions.acquire(registration.runtimeId);

  await started.promise;

  const controller = new AbortController();

  const reason = new DOMException("Assignment cancelled", "AbortError");

  const pending = sessions.acquireCodeRuntime(
    runtimeIdentity(userId, conversationId),
    controller.signal,
  );

  controller.abort(reason);

  proceed.resolve();

  await expect(pending).rejects.toBe(reason);

  const lease = await active;
  await lease.release();

  clock = 101;

  await sessions.sweep();

  expect(events).toStrictEqual(["start", "checkpoint", "stop"]);
});

it("passes CodeAPI cancellation through to VM startup", async () => {
  const controller = new AbortController();

  const reason = new DOMException("Assignment cancelled", "AbortError");

  let receivedSignal: AbortSignal | undefined;

  const sessions = manager({
    ...backend,
    start: async (session, restore, signal) => {
      receivedSignal = signal;

      controller.abort(reason);

      signal?.throwIfAborted();

      return await backend.start(session, restore);
    },
  });

  await expect(
    sessions.acquireCodeRuntime(
      runtimeIdentity(userId, conversationId),
      controller.signal,
    ),
  ).rejects.toBe(reason);

  expect({ receivedSignal, events }).toStrictEqual({
    receivedSignal: controller.signal,
    events: [],
  });
});

it.each(["startup", "lease-save"])(
  "cleans up cancellation at the %s boundary",
  async (stage) => {
    const controller = new AbortController();

    const reason = new DOMException("Assignment cancelled", "AbortError");

    const save = store.save.bind(store);

    let saves = 0;

    store.save = async (session) => {
      await save(session);

      saves += 1;

      if (stage === "lease-save" && saves === 2) {
        controller.abort(reason);
      }
    };

    const sessions = manager({
      ...backend,
      start: async (session, restore) => {
        const guest = await backend.start(session, restore);

        if (stage === "startup") {
          controller.abort(reason);
        }

        return guest;
      },
    });

    await expect(
      sessions.acquireCodeRuntime(
        runtimeIdentity(userId, conversationId),
        controller.signal,
      ),
    ).rejects.toBe(reason);

    clock = 101;

    await sessions.sweep();

    expect(events).toStrictEqual(
      stage === "startup" ? ["start", "stop"] : ["start", "checkpoint", "stop"],
    );
  },
);

it("preserves another caller's lease when CodeAPI acquisition is cancelled", async () => {
  const sessions = manager();

  const active = await sessions.register(userId, conversationId);

  const lease = await sessions.acquire(active.runtimeId);

  const controller = new AbortController();

  const reason = new DOMException("Assignment cancelled", "AbortError");

  const save = store.save.bind(store);

  store.save = async (session) => {
    await save(session);

    controller.abort(reason);
  };

  await expect(
    sessions.acquireCodeRuntime(active.runtimeId, controller.signal),
  ).rejects.toBe(reason);

  clock = 101;

  await sessions.sweep();

  expect(events).toStrictEqual(["start"]);

  await lease.release();

  clock = 202;

  await sessions.sweep();

  expect(events).toStrictEqual(["start", "checkpoint", "stop"]);
});

it("does not persist registration cancelled during session lookup", async () => {
  const controller = new AbortController();
  const reason = new DOMException("MCP request cancelled", "AbortError");
  store.load = async () => {
    controller.abort(reason);
  };

  await expect(
    manager().register(userId, conversationId, controller.signal),
  ).rejects.toBe(reason);

  expect({ events, records: [...records] }).toStrictEqual({
    events: [],
    records: [],
  });
});

it.each(["register", "acquire"] as const)(
  "skips cancelled %s while preserving another caller's startup",
  async (operation) => {
    const started = Promise.withResolvers<void>();
    const proceed = Promise.withResolvers<void>();
    const sessions = manager({
      ...backend,
      start: async (session, restore) => {
        started.resolve();
        await proceed.promise;
        return await backend.start(session, restore);
      },
    });
    const registration = await sessions.register(userId, conversationId);
    const active = sessions.acquire(registration.runtimeId);
    await started.promise;
    const controller = new AbortController();
    const reason = new DOMException("MCP request cancelled", "AbortError");
    const pending =
      operation === "register"
        ? sessions.register(userId, conversationId, controller.signal)
        : sessions.acquire(
            runtimeIdentity(userId, conversationId),
            controller.signal,
          );
    controller.abort(reason);
    proceed.resolve();

    await expect(pending).rejects.toBe(reason);
    const previousLease = await active;
    await previousLease.release();
    const session = previousLease.session;
    const lease = await sessions.acquire(session.runtimeId);

    expect({ events, guest: lease.guest }).toStrictEqual({
      events: ["start"],
      guest: {
        socket: `/private/${session.runtimeId}.sock`,
        bootId: "test-boot",
      },
    });

    await lease.release();
    await sessions.shutdown();
  },
);

it("passes acquisition cancellation to VM startup", async () => {
  const id = runtimeIdentity(userId, conversationId);
  const seed = manager();
  await seed.register(userId, conversationId);
  await seed.shutdown();

  const controller = new AbortController();
  const reason = new DOMException("MCP request cancelled", "AbortError");
  let receivedSignal: AbortSignal | undefined;
  const sessions = manager({
    ...backend,
    start: async (session, restore, signal) => {
      receivedSignal = signal;
      controller.abort(reason);
      signal?.throwIfAborted();
      return await backend.start(session, restore);
    },
  });

  await expect(sessions.acquire(id, controller.signal)).rejects.toBe(reason);
  expect({ receivedSignal, events }).toStrictEqual({
    receivedSignal: controller.signal,
    events: [],
  });
  await sessions.shutdown();
});

it("registers and renews conversation activity without booting a VM", async () => {
  const sessions = manager();
  const original = await sessions.register(userId, conversationId);
  clock = 900;
  const renewed = await sessions.register(userId, conversationId);
  await sessions.shutdown();

  expect({ original, renewed, events }).toStrictEqual({
    original: {
      runtimeId: runtimeIdentity(userId, conversationId),
      conversationId,
      userId,
      generation: 1,
      lastUsed: 0,
      checkpoint: false,
      expired: false,
      resetReason: "A new conversation workspace was created.",
      quarantine: null,
    },
    renewed: {
      runtimeId: runtimeIdentity(userId, conversationId),
      conversationId,
      userId,
      generation: 1,
      lastUsed: 900,
      checkpoint: false,
      expired: false,
      resetReason: "A new conversation workspace was created.",
      quarantine: null,
    },
    events: [],
  });
});

it("renews retention without postponing VM suspension on text-only activity", async () => {
  const sessions = manager();
  const session = await sessions.register(userId, conversationId);
  const lease = await sessions.acquire(session.runtimeId);
  await lease.release();

  clock = 90;
  await sessions.register(userId, conversationId);
  clock = 101;
  await sessions.sweep();

  expect({ session: records.get(session.runtimeId), events }).toStrictEqual({
    session: { ...session, checkpoint: true, lastUsed: 90 },
    events: ["start", "checkpoint", "stop"],
  });
});
