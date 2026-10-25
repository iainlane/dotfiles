import {
  ConversationPrincipalError,
  RuntimeNotRegisteredError,
  ConversationIdError,
  SessionBusyError,
  SessionClosingError,
} from "./errors.ts";
import { beforeEach, expect, it } from "vitest";
import {
  SessionManager,
  type GuestBackend,
  type Session,
  type SessionStore,
} from "./sessions.ts";
import { runtimeIdentity } from "./identity.ts";

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

function manager(): SessionManager {
  return new SessionManager({
    store,
    userId,
    idleMs: 100,
    retentionMs: 1000,
    backend,
    now: () => clock,
  });
}

class LeaseSaveError extends Error {
  constructor() {
    super("The session lease could not be saved");

    this.name = "LeaseSaveError";
  }
}

it("rejects queued conversation activation after shutdown starts", async () => {
  const sessions = manager();

  const activation = sessions.activate(userId, conversationId);
  const shutdown = sessions.shutdown();

  await expect(activation).rejects.toThrow(SessionClosingError);

  await shutdown;

  expect({ events, records: [...records] }).toStrictEqual({
    events: [],
    records: [],
  });
});

it("drains a guest after saving a new lease fails", async () => {
  const sessions = manager();

  const active = await sessions.activate(userId, conversationId);

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
    sessions.activate("another-user", conversationId),
  ).rejects.toThrow(ConversationPrincipalError);

  await expect(
    sessions.acquire("rt_0000000000000000000000000000000000000000"),
  ).rejects.toThrow(RuntimeNotRegisteredError);

  expect(events).toStrictEqual([]);
});

it("uses one VM for concurrent CodeAPI and MCP leases", async () => {
  const sessions = manager();

  const session = await sessions.activate(userId, conversationId);

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

  const original = await sessions.activate(userId, conversationId);

  clock = 101;

  await sessions.sweep();

  const resumed = await sessions.activate(userId, conversationId);

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

  const original = await sessions.activate(userId, conversationId);

  failCheckpoint = true;

  clock = 101;

  await expect(sessions.sweep()).rejects.toThrow(CheckpointInterruptedError);

  const resumed = await sessions.acquire(original.runtimeId);

  expect(events).toStrictEqual(["start", "checkpoint"]);

  await resumed.release();
});

it("extends retention on conversation activity and deletes expired work", async () => {
  const sessions = manager();

  await sessions.activate(userId, conversationId);

  clock = 900;

  await sessions.activate(userId, conversationId);

  clock = 1500;

  await sessions.sweep();

  clock = 1901;

  await sessions.sweep();

  const recreated = await sessions.activate(userId, conversationId);

  expect({
    generation: recreated.generation,
    reset: recreated.resetReason,
    events,
  }).toStrictEqual({
    generation: 2,
    reset:
      "The previous workspace expired and was deleted, including unpushed work.",
    events: ["start", "checkpoint", "stop", "remove", "start"],
  });
});

it("recovers durable registration and reports a controller restart", async () => {
  const first = manager();

  const original = await first.activate(userId, conversationId);

  clock = 101;

  await first.sweep();

  const second = manager();

  const resumed = await second.activate(userId, conversationId);

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

  await expect(sessions.activate(userId, "../../outside")).rejects.toThrow(
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

  const session = await sessions.activate(userId, conversationId);

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

  const original = await sessions.activate(userId, conversationId);

  await sessions.reset(original.runtimeId);

  const session = await sessions.activate(userId, conversationId);

  expect({
    generation: session.generation,
    events,
    reason: session.resetReason,
  }).toStrictEqual({
    generation: 2,
    events: ["start", "stop", "remove", "start"],
    reason:
      "The workspace was explicitly reset and unpushed work was discarded.",
  });
});

it("binds a later conversation hook to the VM already acquired by authenticated prewarming", async () => {
  const sessions = manager();

  const id = runtimeIdentity(userId, conversationId);

  const prewarm = await sessions.acquireCodeRuntime(id);

  await prewarm.release();

  const registered = await sessions.activate(userId, conversationId);

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
