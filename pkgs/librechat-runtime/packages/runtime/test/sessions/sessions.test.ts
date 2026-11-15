import { once } from "node:events";
import {
  ConversationPrincipalError,
  RuntimeNotRegisteredError,
  ConversationIdError,
  SessionBusyError,
  SessionClosingError,
  WorkspaceStartupCleanupError,
} from "#runtime/platform/errors";
import { beforeEach, expect, it } from "vitest";
import {
  SessionManager,
  type Guest,
  type GuestBackend,
  type Session,
  type SessionStore,
} from "#runtime/sessions/sessions";
import { runtimeIdentity } from "#runtime/platform/identity";

const userId = "0123456789abcdef01234567";

const conversationId = "ea277865-9bbd-45ec-9cd2-234cf9dc9169";

const runtimeId = runtimeIdentity(userId, conversationId);

class VmAlreadyRunningError extends Error {
  constructor() {
    super("The workspace disk is locked by a running VM");

    this.name = "VmAlreadyRunningError";
  }
}

class VmNotRunningError extends Error {
  constructor() {
    super("The workspace has no running VM");

    this.name = "VmNotRunningError";
  }
}

class MissingCheckpointError extends Error {
  constructor() {
    super("The workspace has no checkpoint to restore");

    this.name = "MissingCheckpointError";
  }
}

class WorkspaceInUseError extends Error {
  constructor() {
    super("A running VM still uses the workspace");

    this.name = "WorkspaceInUseError";
  }
}

class CheckpointInterruptedError extends Error {
  constructor() {
    super("Checkpoint interrupted");

    this.name = "CheckpointInterruptedError";
  }
}

class LeaseSaveError extends Error {
  constructor() {
    super("The session lease could not be saved");

    this.name = "LeaseSaveError";
  }
}

class BootGate {
  readonly began = Promise.withResolvers<void>();
  private readonly opened = Promise.withResolvers<void>();

  open(): void {
    this.opened.resolve();
  }

  async pass(signal?: AbortSignal): Promise<void> {
    signal?.throwIfAborted();

    this.began.resolve();

    await Promise.race([
      this.opened.promise,
      ...(signal === undefined ? [] : [once(signal, "abort")]),
    ]);

    signal?.throwIfAborted();
  }
}

interface Workspace {
  vm: "running" | "stopped";
  checkpoint: boolean;
  restored: boolean;
}

class FakeGuestBackend implements GuestBackend {
  readonly workspaces = new Map<string, Workspace>();
  gate: BootGate | undefined;
  onBoot: (() => void) | undefined;
  checkpointFailure: Error | undefined;
  stopFailure: Error | undefined;

  async start(
    session: Session,
    restore: boolean,
    signal?: AbortSignal,
  ): Promise<Guest> {
    await this.gate?.pass(signal);

    const workspace = this.workspaces.get(session.runtimeId);

    if (workspace?.vm === "running") {
      throw new VmAlreadyRunningError();
    }

    if (restore && workspace?.checkpoint !== true) {
      throw new MissingCheckpointError();
    }

    this.workspaces.set(session.runtimeId, {
      vm: "running",
      checkpoint: workspace?.checkpoint ?? false,
      restored: restore,
    });

    this.onBoot?.();

    return {
      socket: `/private/${session.runtimeId}.sock`,
      bootId: "test-boot",
    };
  }

  async checkpoint(session: Session): Promise<void> {
    const workspace = this.running(session);

    if (this.checkpointFailure !== undefined) {
      throw this.checkpointFailure;
    }

    workspace.checkpoint = true;
  }

  async stop(session: Session): Promise<void> {
    const workspace = this.running(session);

    if (this.stopFailure !== undefined) {
      throw this.stopFailure;
    }

    workspace.vm = "stopped";
  }

  async remove(session: Session): Promise<void> {
    if (this.workspaces.get(session.runtimeId)?.vm === "running") {
      throw new WorkspaceInUseError();
    }

    this.workspaces.delete(session.runtimeId);
  }

  private running(session: Session): Workspace {
    const workspace = this.workspaces.get(session.runtimeId);

    if (workspace?.vm !== "running") {
      throw new VmNotRunningError();
    }

    return workspace;
  }
}

class FakeSessionStore implements SessionStore {
  readonly records = new Map<string, Session>();
  onLoad: (() => void) | undefined;
  onSave: ((session: Session) => void) | undefined;
  saveFailure: Error | undefined;

  async load(id: string): Promise<unknown> {
    this.onLoad?.();

    return structuredClone(this.records.get(id));
  }

  async save(session: Session): Promise<void> {
    if (this.saveFailure !== undefined) {
      throw this.saveFailure;
    }

    this.records.set(session.runtimeId, structuredClone(session));

    this.onSave?.(session);
  }

  async list(): Promise<string[]> {
    return [...this.records.keys()];
  }
}

let store: FakeSessionStore;

let backend: FakeGuestBackend;

let clock = 0;

beforeEach(() => {
  store = new FakeSessionStore();

  backend = new FakeGuestBackend();

  clock = 0;
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

const guest = { socket: `/private/${runtimeId}.sock`, bootId: "test-boot" };

const suspended = { vm: "stopped", checkpoint: true, restored: false };

it("rejects queued conversation registration after shutdown starts", async () => {
  const sessions = manager();

  const registration = sessions.register(userId, conversationId);
  const shutdown = sessions.shutdown();

  await expect(registration).rejects.toStrictEqual(new SessionClosingError());

  await shutdown;

  expect({
    workspaces: [...backend.workspaces],
    records: [...store.records],
  }).toStrictEqual({ workspaces: [], records: [] });
});

it("drains a guest after saving a new lease fails", async () => {
  const sessions = manager();

  const active = await sessions.register(userId, conversationId);

  store.saveFailure = new LeaseSaveError();

  await expect(sessions.acquire(active.runtimeId)).rejects.toStrictEqual(
    new LeaseSaveError(),
  );

  store.saveFailure = undefined;

  clock = 101;

  await sessions.sweep();

  await sessions.shutdown();

  expect(backend.workspaces.get(runtimeId)).toStrictEqual(suspended);
});

it("rejects other principals and unregistered runtime identities", async () => {
  const sessions = manager();

  await expect(
    sessions.register("another-user", conversationId),
  ).rejects.toStrictEqual(new ConversationPrincipalError());

  await expect(
    sessions.acquire("rt_0000000000000000000000000000000000000000"),
  ).rejects.toStrictEqual(new RuntimeNotRegisteredError());

  expect([...backend.workspaces]).toStrictEqual([]);
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

  expect({
    code: code.guest,
    mcp: mcp.guest,
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    code: guest,
    mcp: guest,
    workspace: { vm: "running", checkpoint: false, restored: false },
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

  const idle = structuredClone(backend.workspaces.get(runtimeId));

  const resumed = await sessions.register(userId, conversationId);
  const resumedLease = await sessions.acquire(resumed.runtimeId);
  await resumedLease.release();

  expect({
    runtime: resumed.runtimeId,
    generation: resumed.generation,
    originalGeneration: original.generation,
    idle,
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    runtime: original.runtimeId,
    generation: 1,
    originalGeneration: 1,
    idle: suspended,
    workspace: { vm: "running", checkpoint: true, restored: true },
  });
});

it("keeps a VM running when checkpointing fails", async () => {
  const sessions = manager();

  const original = await sessions.register(userId, conversationId);

  const lease = await sessions.acquire(original.runtimeId);
  await lease.release();

  backend.checkpointFailure = new CheckpointInterruptedError();

  clock = 101;

  await expect(sessions.sweep()).rejects.toStrictEqual(
    new CheckpointInterruptedError(),
  );

  const resumed = await sessions.acquire(original.runtimeId);

  expect({
    guest: resumed.guest,
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    guest,
    workspace: { vm: "running", checkpoint: false, restored: false },
  });

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

  const retained = structuredClone(backend.workspaces.get(runtimeId));

  clock = 1901;

  await sessions.sweep();

  const recreated = await sessions.register(userId, conversationId);

  expect({
    generation: recreated.generation,
    reset: recreated.resetReason,
    retained,
    workspaces: [...backend.workspaces],
  }).toStrictEqual({
    generation: 2,
    reset:
      "The previous workspace expired and was deleted, including unpushed work.",
    retained: suspended,
    workspaces: [],
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

  const state = store.records.get(original.runtimeId);

  expect({
    runtime: resumed.runtimeId,
    generation: resumed.generation,
    workspace: backend.workspaces.get(runtimeId),
    saved: typeof state === "object",
  }).toStrictEqual({
    runtime: original.runtimeId,
    generation: 1,
    workspace: { vm: "running", checkpoint: true, restored: true },
    saved: true,
  });
});

it("does not derive host paths from conversation IDs", async () => {
  const sessions = manager();

  await expect(
    sessions.register(userId, "../../outside"),
  ).rejects.toStrictEqual(new ConversationIdError());

  expect({
    workspaces: [...backend.workspaces],
    records: [...store.records],
  }).toStrictEqual({ workspaces: [], records: [] });
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

  await expect(sessions.shutdown()).rejects.toStrictEqual(
    new SessionBusyError(),
  );

  await expect(sessions.acquire(session.runtimeId)).rejects.toStrictEqual(
    new SessionClosingError(),
  );

  const busy = structuredClone(backend.workspaces.get(runtimeId));

  await lease.release();

  await sessions.shutdown();

  expect({
    busy,
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    busy: { vm: "running", checkpoint: false, restored: false },
    workspace: suspended,
  });
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
    workspaces: [...backend.workspaces],
    reason: session.resetReason,
  }).toStrictEqual({
    generation: 2,
    workspaces: [],
    reason:
      "The workspace was explicitly reset and unpushed work was discarded.",
  });
});

it("binds a later conversation hook to the VM already acquired by authenticated prewarming", async () => {
  const sessions = manager();

  const prewarm = await sessions.acquireCodeRuntime(runtimeId);

  await prewarm.release();

  const registered = await sessions.register(userId, conversationId);

  const mcp = await sessions.acquire(runtimeId);

  expect({
    conversation: registered.conversationId,
    guest: mcp.guest,
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    conversation: conversationId,
    guest: prewarm.guest,
    workspace: { vm: "running", checkpoint: false, restored: false },
  });

  await mcp.release();
});

it("skips a cancelled CodeAPI acquisition queued behind another VM startup", async () => {
  const gate = new BootGate();

  backend.gate = gate;

  const sessions = manager();

  const registration = await sessions.register(userId, conversationId);
  const active = sessions.acquire(registration.runtimeId);

  await gate.began.promise;

  const controller = new AbortController();

  const reason = new DOMException("Assignment cancelled", "AbortError");

  const pending = sessions.acquireCodeRuntime(runtimeId, controller.signal);

  controller.abort(reason);

  gate.open();

  await expect(pending).rejects.toBe(reason);

  const lease = await active;
  await lease.release();

  clock = 101;

  await sessions.sweep();

  expect(backend.workspaces.get(runtimeId)).toStrictEqual(suspended);
});

it("passes CodeAPI cancellation through to VM startup", async () => {
  const gate = new BootGate();

  backend.gate = gate;

  const controller = new AbortController();

  const reason = new DOMException("Assignment cancelled", "AbortError");

  const pending = manager().acquireCodeRuntime(runtimeId, controller.signal);

  await gate.began.promise;

  controller.abort(reason);

  gate.open();

  await expect(pending).rejects.toBe(reason);

  expect([...backend.workspaces]).toStrictEqual([]);
});

it.each([
  { stage: "startup", workspace: { ...suspended, checkpoint: false } },
  { stage: "lease-save", workspace: suspended },
])(
  "cleans up cancellation at the $stage boundary",
  async ({ stage, workspace }) => {
    const controller = new AbortController();

    const reason = new DOMException("Assignment cancelled", "AbortError");

    if (stage === "startup") {
      backend.onBoot = () => controller.abort(reason);
    }

    if (stage === "lease-save") {
      store.onSave = (session) => {
        if (backend.workspaces.get(session.runtimeId)?.vm === "running") {
          controller.abort(reason);
        }
      };
    }

    const sessions = manager();

    await expect(
      sessions.acquireCodeRuntime(runtimeId, controller.signal),
    ).rejects.toBe(reason);

    clock = 101;

    await sessions.sweep();

    expect(backend.workspaces.get(runtimeId)).toStrictEqual(workspace);
  },
);

it("preserves another caller's lease when CodeAPI acquisition is cancelled", async () => {
  const sessions = manager();

  const active = await sessions.register(userId, conversationId);

  const lease = await sessions.acquire(active.runtimeId);

  const controller = new AbortController();

  const reason = new DOMException("Assignment cancelled", "AbortError");

  store.onSave = () => controller.abort(reason);

  await expect(
    sessions.acquireCodeRuntime(active.runtimeId, controller.signal),
  ).rejects.toBe(reason);

  clock = 101;

  await sessions.sweep();

  const leased = structuredClone(backend.workspaces.get(runtimeId));

  await lease.release();

  clock = 202;

  await sessions.sweep();

  expect({
    leased,
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    leased: { vm: "running", checkpoint: false, restored: false },
    workspace: suspended,
  });
});

it("does not persist registration cancelled during session lookup", async () => {
  const controller = new AbortController();
  const reason = new DOMException("MCP request cancelled", "AbortError");
  store.onLoad = () => controller.abort(reason);

  await expect(
    manager().register(userId, conversationId, controller.signal),
  ).rejects.toBe(reason);

  expect({
    workspaces: [...backend.workspaces],
    records: [...store.records],
  }).toStrictEqual({ workspaces: [], records: [] });
});

it.each(["register", "acquire"] as const)(
  "skips cancelled %s while preserving another caller's startup",
  async (operation) => {
    const gate = new BootGate();
    backend.gate = gate;
    const sessions = manager();
    const registration = await sessions.register(userId, conversationId);
    const active = sessions.acquire(registration.runtimeId);
    await gate.began.promise;
    const controller = new AbortController();
    const reason = new DOMException("MCP request cancelled", "AbortError");
    const pending =
      operation === "register"
        ? sessions.register(userId, conversationId, controller.signal)
        : sessions.acquire(runtimeId, controller.signal);
    controller.abort(reason);
    gate.open();

    await expect(pending).rejects.toBe(reason);
    const previousLease = await active;
    await previousLease.release();
    const lease = await sessions.acquire(previousLease.session.runtimeId);

    expect({
      workspace: backend.workspaces.get(runtimeId),
      guest: lease.guest,
    }).toStrictEqual({
      workspace: { vm: "running", checkpoint: false, restored: false },
      guest,
    });

    await lease.release();
    await sessions.shutdown();
  },
);

it("passes acquisition cancellation to VM startup", async () => {
  const seed = manager();
  await seed.register(userId, conversationId);
  await seed.shutdown();

  const gate = new BootGate();
  backend.gate = gate;
  const controller = new AbortController();
  const reason = new DOMException("MCP request cancelled", "AbortError");
  const sessions = manager();
  const pending = sessions.acquire(runtimeId, controller.signal);
  await gate.began.promise;
  controller.abort(reason);
  gate.open();

  await expect(pending).rejects.toBe(reason);
  expect([...backend.workspaces]).toStrictEqual([]);
  await sessions.shutdown();
});

it("registers and renews conversation activity without booting a VM", async () => {
  const sessions = manager();
  const original = await sessions.register(userId, conversationId);
  clock = 900;
  const renewed = await sessions.register(userId, conversationId);
  await sessions.shutdown();

  expect({
    original,
    renewed,
    workspaces: [...backend.workspaces],
  }).toStrictEqual({
    original: {
      runtimeId,
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
      runtimeId,
      conversationId,
      userId,
      generation: 1,
      lastUsed: 900,
      checkpoint: false,
      expired: false,
      resetReason: "A new conversation workspace was created.",
      quarantine: null,
    },
    workspaces: [],
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

  expect({
    session: store.records.get(session.runtimeId),
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    session: { ...session, checkpoint: true, lastUsed: 90 },
    workspace: suspended,
  });
});

it("preserves cancellation and retries failed startup cancellation cleanup on shutdown", async () => {
  const controller = new AbortController();
  const reason = new DOMException("Assignment cancelled", "AbortError");
  const cleanup = new Error("fixture stop failed");
  backend.onBoot = () => controller.abort(reason);
  backend.stopFailure = cleanup;
  const sessions = manager();

  await expect(
    sessions.acquireCodeRuntime(runtimeId, controller.signal),
  ).rejects.toStrictEqual(
    new WorkspaceStartupCleanupError(guest, reason, cleanup),
  );
  const failed = structuredClone(backend.workspaces.get(runtimeId));

  backend.stopFailure = undefined;
  await sessions.shutdown();

  expect({
    failed,
    workspace: backend.workspaces.get(runtimeId),
  }).toStrictEqual({
    failed: { vm: "running", checkpoint: false, restored: false },
    workspace: { vm: "stopped", checkpoint: false, restored: false },
  });
});
