import { once } from "node:events";
import { StatusCodes } from "http-status-codes";
import { z } from "zod";
import {
  QuarantineTargetError,
  WorkspaceRecoveryError,
} from "#runtime/platform/errors";
import { beforeEach, expect, it } from "vitest";
import {
  QemuBackend,
  VmCheckpointError,
  VmQuiesceError,
  VmRestoreError,
  VmStartupCleanupError,
  type VmFiles,
} from "#runtime/vm/vm-backend";
import type {
  Command,
  ManagedProcess,
  ProcessRunner,
} from "#runtime/platform/processes";
import { SessionManager, type Session } from "#runtime/sessions/sessions";

const session: Session = {
  runtimeId: `rt_${"a".repeat(40)}`,
  conversationId: null,
  userId: "0123456789abcdef01234567",
  generation: 1,
  lastUsed: 0,
  checkpoint: false,
  expired: false,
  quarantine: null,
  resetReason: "",
};

const guestAddress = { socket: "/control", bootId: "boot" };

class FixtureDeadlines {
  private now = 0;
  private readonly pending: { at: number; controller: AbortController }[] = [];

  signal(milliseconds: number): AbortSignal {
    const controller = new AbortController();

    this.pending.push({ at: this.now + milliseconds, controller });

    return controller.signal;
  }

  advance(milliseconds: number): void {
    this.now += milliseconds;

    for (const { at, controller } of this.pending) {
      if (at <= this.now) {
        controller.abort(deadlineExpired());
      }
    }
  }
}

function deadlineExpired(): DOMException {
  return new DOMException("The guest control deadline expired", "TimeoutError");
}

class GuestUnreachableError extends Error {
  constructor() {
    super("The guest control socket is not accepting connections");
    this.name = "GuestUnreachableError";
  }
}

class StopFailedError extends Error {
  constructor() {
    super("fixture stop failure");
    this.name = "StopFailedError";
  }
}

class SnapshotFailedError extends Error {
  constructor() {
    super("snapshot failed");
    this.name = "SnapshotFailedError";
  }
}

class UnexpectedCommandError extends Error {
  constructor() {
    super("The backend ran a command outside QEMU");
    this.name = "UnexpectedCommandError";
  }
}

function stream(text: string): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(text));

      controller.close();
    },
  });
}

interface GuestState {
  bound: string | undefined;
  mcp: "running" | "stopped";
  workspace: string;
}

interface Failure {
  mode: "response" | "transport" | "body";
  error: Error;
}

class FakeQemu implements ManagedProcess {
  state: "running" | "stopped" = "running";
  paused: boolean;
  private readonly exit = Promise.withResolvers<void>();
  private readonly machine: FakeMachine;

  constructor(machine: FakeMachine, paused: boolean) {
    this.machine = machine;
    this.paused = paused;
  }

  get exited(): Promise<void> {
    return this.exit.promise;
  }

  running(): boolean {
    return this.state === "running";
  }

  async stop(): Promise<void> {
    if (this.machine.stopFailure !== undefined) {
      throw this.machine.stopFailure;
    }

    this.state = "stopped";
    this.exit.resolve();
  }

  crash(error: unknown): void {
    this.state = "stopped";
    this.exit.reject(error);
  }
}

class FakeMachine implements VmFiles {
  health: "ready" | "legacy" | "without-snapshots" | "hang" | "unavailable" =
    "ready";
  readonly failures = new Map<string, Failure>();
  readonly durations = new Map<string, number>();
  cancellation: { stage: string; abort(): void } | undefined;
  stalls = false;
  readonly stalled = Promise.withResolvers<void>();
  stopFailure: Error | undefined;
  snapshotFailure: Error | undefined;
  readonly deadlines = new FixtureDeadlines();

  prepared = false;
  checkpoint: string | undefined = "saved workspace";
  vmSnapshot: GuestState | undefined;
  process: FakeQemu | undefined;
  guest: GuestState | undefined;
  private internalSnapshot: GuestState | undefined;

  state(): unknown {
    return {
      prepared: this.prepared,
      process: this.process?.state,
      guest: this.guest,
      checkpoint: this.checkpoint,
      vmSnapshot: this.vmSnapshot,
    };
  }

  private reach(stage: string): void {
    if (this.cancellation?.stage === stage) {
      this.cancellation.abort();
    }
  }

  async prepare(
    _session: Session,
    restore?: boolean,
  ): ReturnType<VmFiles["prepare"]> {
    this.prepared = true;

    this.reach("prepare");

    return {
      runtime: {
        executable: "/qemu",
        architecture: "aarch64",
        accelerator: "hvf",
        forwarder: "/bin/socat",
        memoryMiB: 4096,
        cpus: 2,
      },
      disk: "/disk",
      kernel: "/kernel",
      initrd: "/initrd",
      init: "/init",
      controlSocket: guestAddress.socket,
      monitorSocket: "/monitor",
      ...(restore === true && this.vmSnapshot !== undefined
        ? { snapshot: "librechat" as const }
        : {}),
    };
  }

  async readCheckpoint(): Promise<ReadableStream<Uint8Array>> {
    return stream(z.string().parse(this.checkpoint));
  }

  async saveCheckpoint(
    _session: Session,
    body: ReadableStream<Uint8Array>,
  ): Promise<void> {
    this.checkpoint = await new Response(body).text();
  }

  async saveSnapshot(): Promise<void> {
    if (this.snapshotFailure !== undefined) {
      throw this.snapshotFailure;
    }

    this.vmSnapshot = structuredClone(this.internalSnapshot);
  }

  async remove(): Promise<void> {
    this.checkpoint = undefined;
    this.vmSnapshot = undefined;
  }

  readonly processes: ProcessRunner = {
    run: async () => {
      throw new UnexpectedCommandError();
    },
    start: async (command: Command) => {
      const process = new FakeQemu(this, command.args.includes("-S"));

      this.process = process;
      this.guest = command.args.includes("-loadvm")
        ? structuredClone(this.vmSnapshot)
        : { bound: undefined, mcp: "stopped", workspace: "new workspace" };

      this.reach("qemu");

      return process;
    },
  };

  readonly saveVmSnapshot = async (
    _socket: string,
    persist: () => Promise<void>,
  ): Promise<void> => {
    this.internalSnapshot = structuredClone(this.guest);

    await persist();
  };

  readonly resumeVm = async (): Promise<void> => {
    if (this.process !== undefined) {
      this.process.paused = false;
    }
  };

  readonly delay = async (
    _milliseconds: number,
    signal?: AbortSignal,
  ): Promise<void> => {
    signal?.throwIfAborted();

    if (this.stalls && signal !== undefined) {
      await this.stall(signal);
    }
  };

  private async stall(signal: AbortSignal): Promise<never> {
    const aborted = once(signal, "abort");

    this.stalled.resolve();

    await aborted;

    signal.throwIfAborted();

    throw new GuestUnreachableError();
  }

  readonly fetch = async (
    _socket: string,
    request: Request,
  ): Promise<Response> => {
    const path = new URL(request.url).pathname;
    const guest = this.guest;

    if (this.process?.running() !== true || this.process.paused || !guest) {
      throw new GuestUnreachableError();
    }

    const duration = this.durations.get(path);

    if (duration !== undefined) {
      this.deadlines.advance(duration);
    }

    this.reach(path);

    request.signal.throwIfAborted();

    switch (path) {
      case "/health":
        return await this.healthResponse(request);
      case "/control/bind": {
        const binding = z
          .object({ runtimeId: z.string() })
          .parse(await request.json());

        guest.bound = binding.runtimeId;

        return new Response(null);
      }
      case "/runner/api/v2/session/restore":
        if (guest.bound === undefined || guest.mcp === "running") {
          return new Response(null, { status: StatusCodes.CONFLICT });
        }

        return this.failure(path) ?? this.restore(guest, await request.text());
      case "/control/resume":
        if (guest.bound === undefined) {
          return new Response(null, { status: StatusCodes.CONFLICT });
        }

        return this.failure(path) ?? this.startMcp(guest);
      case "/control/quiesce":
        guest.mcp = "stopped";

        return this.failure(path) ?? new Response(null);
      case "/runner/api/v2/session/checkpoint":
        if (guest.mcp === "running") {
          return new Response(null, { status: StatusCodes.CONFLICT });
        }

        return this.failure(path) ?? new Response(stream(guest.workspace));
    }

    return new Response(null, { status: StatusCodes.NOT_FOUND });
  };

  private async healthResponse(request: Request): Promise<Response> {
    switch (this.health) {
      case "ready":
        return Response.json({ resumeClock: true });
      case "without-snapshots":
        return Response.json({ resumeClock: false });
      case "legacy":
        return Response.json({ runtimeId: session.runtimeId });
      case "hang":
        return await this.stall(request.signal);
      case "unavailable":
        break;
    }

    return new Response(null, { status: StatusCodes.SERVICE_UNAVAILABLE });
  }

  private restore(guest: GuestState, workspace: string): Response {
    guest.workspace = workspace;

    return new Response(null);
  }

  private startMcp(guest: GuestState): Response {
    guest.mcp = "running";

    return new Response(null);
  }

  private failure(path: string): Response | undefined {
    const failure = this.failures.get(path);

    if (failure === undefined) {
      return undefined;
    }

    if (failure.mode === "transport") {
      throw failure.error;
    }

    if (failure.mode === "body") {
      return new Response(
        new ReadableStream({
          cancel: () => {
            throw failure.error;
          },
        }),
      );
    }

    return new Response(null, {
      status: StatusCodes.INTERNAL_SERVER_ERROR,
    });
  }
}

class FixtureHost {
  readonly records = new Map<string, Session>();
  sessions: SessionManager | undefined;
  failure: unknown;

  readonly onFailure = async (failed: Session): Promise<void> => {
    await this.sessions?.quarantine(failed.runtimeId, "The VM exited");
  };

  readonly onError = (error: unknown): void => {
    this.failure = error;
  };

  manage(vm: QemuBackend): void {
    this.sessions = new SessionManager({
      backend: vm,
      store: {
        load: async (id) => this.records.get(id),
        save: async (saved) => {
          this.records.set(saved.runtimeId, structuredClone(saved));
        },
        list: async () => [...this.records.keys()],
      },
      userId: session.userId,
      idleMs: 1000,
      retentionMs: 10000,
      now: () => 0,
    });
  }
}

let machine: FakeMachine;

let host: FixtureHost;

beforeEach(() => {
  machine = new FakeMachine();

  host = new FixtureHost();
});

function backend(): QemuBackend {
  return new QemuBackend({
    saveVmSnapshot: machine.saveVmSnapshot,
    resumeVm: machine.resumeVm,
    boot: {
      ironPort: 3128,
      fileRelayPort: 3190,
      archiveBrokerPort: 3194,
    },
    files: machine,
    processes: machine.processes,
    fetch: machine.fetch,
    delay: machine.delay,
    timeout: (milliseconds) => machine.deadlines.signal(milliseconds),
    newBootId: () => guestAddress.bootId,
    now: () => 1700000000000,
    caCertificate: "public-ca",
    executionPublicKey: "public-execution-key",
    archiveToken: "read-only-broker-token",
    onFailure: host.onFailure,
    onError: host.onError,
  });
}

const serving: GuestState = {
  bound: session.runtimeId,
  mcp: "running",
  workspace: "new workspace",
};

it.each([
  { path: "/control/bind", elapsed: 90_000 },
  { path: "/control/resume", elapsed: 420_000 },
])("allows the guest operation budget for $path", async ({ path, elapsed }) => {
  machine.durations.set(path, elapsed);

  const vm = backend();

  const guest = await vm.start(session, false);

  await vm.checkpoint(session, guest);

  expect({ guest, state: machine.state() }).toStrictEqual({
    guest: guestAddress,
    state: {
      prepared: true,
      process: "running",
      guest: serving,
      checkpoint: "saved workspace",
      vmSnapshot: serving,
    },
  });
});

it("stops a VM when guest startup exceeds its control deadline", async () => {
  machine.durations.set("/control/resume", 600_000);

  await expect(backend().start(session, false)).rejects.toStrictEqual(
    deadlineExpired(),
  );

  expect(machine.state()).toStrictEqual({
    prepared: true,
    process: "stopped",
    guest: { ...serving, mcp: "stopped" },
    checkpoint: "saved workspace",
    vmSnapshot: undefined,
  });
});

it("restores files before starting MCP processes", async () => {
  await backend().start(session, true);

  expect(machine.state()).toStrictEqual({
    prepared: true,
    process: "running",
    guest: { ...serving, workspace: "saved workspace" },
    checkpoint: "saved workspace",
    vmSnapshot: undefined,
  });
});

it("stops a VM after a failed restore before MCP can read files", async () => {
  machine.failures.set("/runner/api/v2/session/restore", {
    mode: "response",
    error: new VmRestoreError(),
  });

  await expect(backend().start(session, true)).rejects.toStrictEqual(
    new VmRestoreError(),
  );

  expect(machine.state()).toStrictEqual({
    prepared: true,
    process: "stopped",
    guest: { ...serving, mcp: "stopped" },
    checkpoint: "saved workspace",
    vmSnapshot: undefined,
  });
});

it("snapshots the VM without stopping its MCP processes", async () => {
  const vm = backend();

  const guest = await vm.start(session, false);

  await vm.checkpoint(session, guest);

  expect(machine.state()).toStrictEqual({
    prepared: true,
    process: "running",
    guest: serving,
    checkpoint: "saved workspace",
    vmSnapshot: serving,
  });
});

it("propagates snapshot failure without stopping the VM", async () => {
  const vm = backend();
  const guest = await vm.start(session, false);
  machine.snapshotFailure = new SnapshotFailedError();
  await expect(vm.checkpoint(session, guest)).rejects.toStrictEqual(
    new SnapshotFailedError(),
  );
  expect(machine.state()).toStrictEqual({
    prepared: true,
    process: "running",
    guest: serving,
    checkpoint: "saved workspace",
    vmSnapshot: undefined,
  });
});

it("resumes a complete VM snapshot without restoring workspace files", async () => {
  const suspended = { ...serving, workspace: "suspended workspace" };
  machine.vmSnapshot = suspended;
  await backend().start(session, true);
  expect({
    paused: machine.process?.paused,
    state: machine.state(),
  }).toStrictEqual({
    paused: false,
    state: {
      prepared: true,
      process: "running",
      guest: suspended,
      checkpoint: "saved workspace",
      vmSnapshot: suspended,
    },
  });
});

it("resumes MCP and keeps the VM running after a failed checkpoint", async () => {
  machine.health = "without-snapshots";
  const vm = backend();

  const guest = await vm.start(session, false);

  machine.failures.set("/runner/api/v2/session/checkpoint", {
    mode: "response",
    error: new VmCheckpointError(),
  });

  await expect(vm.checkpoint(session, guest)).rejects.toStrictEqual(
    new VmCheckpointError(),
  );

  expect(machine.state()).toStrictEqual({
    prepared: true,
    process: "running",
    guest: serving,
    checkpoint: "saved workspace",
    vmSnapshot: undefined,
  });
});

it.each([
  { mode: "response", error: new WorkspaceRecoveryError() },
  {
    mode: "transport",
    error: new WorkspaceRecoveryError({ cause: new VmCheckpointError() }),
  },
  {
    mode: "body",
    error: new WorkspaceRecoveryError({ cause: new VmCheckpointError() }),
  },
] as const)(
  "reports a recovery failure when resume fails through $mode",
  async ({ mode, error }) => {
    machine.health = "without-snapshots";
    const vm = backend();

    const guest = await vm.start(session, false);

    machine.failures.set("/runner/api/v2/session/checkpoint", {
      mode: "response",
      error: new VmCheckpointError(),
    });
    machine.failures.set("/control/resume", {
      mode,
      error: new VmCheckpointError(),
    });

    await expect(vm.checkpoint(session, guest)).rejects.toStrictEqual(error);

    expect(machine.state()).toStrictEqual({
      prepared: true,
      process: "running",
      guest: { ...serving, mcp: "stopped" },
      checkpoint: "saved workspace",
      vmSnapshot: undefined,
    });
  },
);

it.each(["response", "transport", "body"] as const)(
  "resumes MCP after quiesce fails through %s",
  async (mode) => {
    machine.health = "without-snapshots";
    const vm = backend();

    const guest = await vm.start(session, false);

    machine.failures.set("/control/quiesce", {
      mode,
      error: new VmQuiesceError(),
    });

    await expect(vm.checkpoint(session, guest)).rejects.toStrictEqual(
      new VmQuiesceError(),
    );

    expect(machine.state()).toStrictEqual({
      prepared: true,
      process: "running",
      guest: serving,
      checkpoint: "saved workspace",
      vmSnapshot: undefined,
    });
  },
);

const booted: GuestState = {
  bound: undefined,
  mcp: "stopped",
  workspace: "new workspace",
};

it.each([
  { stage: "before", prepared: false, process: undefined, guest: undefined },
  { stage: "prepare", prepared: true, process: undefined, guest: undefined },
  { stage: "qemu", prepared: true, process: "stopped", guest: booted },
  { stage: "/control/bind", prepared: true, process: "stopped", guest: booted },
  {
    stage: "/runner/api/v2/session/restore",
    prepared: true,
    process: "stopped",
    guest: { ...booted, bound: session.runtimeId },
  },
  {
    stage: "/control/resume",
    prepared: true,
    process: "stopped",
    guest: {
      ...booted,
      bound: session.runtimeId,
      workspace: "saved workspace",
    },
  },
])(
  "stops cancelled startup at $stage",
  async ({ stage, prepared, process, guest }) => {
    const controller = new AbortController();

    const reason = new DOMException("Assignment cancelled", "AbortError");

    machine.cancellation = { stage, abort: () => controller.abort(reason) };

    if (stage === "before") {
      controller.abort(reason);
    }

    await expect(
      backend().start(session, true, controller.signal),
    ).rejects.toBe(reason);

    expect(machine.state()).toStrictEqual({
      prepared,
      process,
      guest,
      checkpoint: "saved workspace",
      vmSnapshot: undefined,
    });
  },
);

it.each([
  { stage: "probe", health: "hang", stalls: false },
  { stage: "delay", health: "unavailable", stalls: true },
] as const)(
  "interrupts the readiness $stage when startup is cancelled",
  async ({ health, stalls }) => {
    const controller = new AbortController();

    const reason = new DOMException("Assignment cancelled", "AbortError");

    machine.health = health;
    machine.stalls = stalls;

    const pending = backend().start(session, false, controller.signal);

    await machine.stalled.promise;

    controller.abort(reason);

    await expect(pending).rejects.toBe(reason);

    expect(machine.state()).toStrictEqual({
      prepared: true,
      process: "stopped",
      guest: booted,
      checkpoint: "saved workspace",
      vmSnapshot: undefined,
    });
  },
);

it.each([
  {
    outcome: "quarantines the registered session",
    registered: true,
    records: [{ ...session, quarantine: "The VM exited" }],
    failure: undefined,
  },
  {
    outcome: "fails the host if the session is not registered",
    registered: false,
    records: [],
    failure: new QuarantineTargetError(),
  },
])(
  "$outcome when a VM exits unexpectedly",
  async ({ registered, records, failure }) => {
    if (registered) {
      host.records.set(session.runtimeId, session);
    }

    const vm = backend();

    host.manage(vm);

    await vm.start(session, false);

    machine.process?.crash(new VmRestoreError());

    await new Promise<void>((resolve) => {
      setImmediate(resolve);
    });

    expect({
      records: [...host.records.values()],
      failure: host.failure,
    }).toStrictEqual({ records, failure });
  },
);

it("keeps older guests on workspace checkpoints", async () => {
  machine.health = "legacy";
  const vm = backend();
  const guest = await vm.start(session, false);
  await vm.checkpoint(session, guest);
  expect(machine.state()).toStrictEqual({
    prepared: true,
    process: "running",
    guest: { ...serving, mcp: "stopped" },
    checkpoint: "new workspace",
    vmSnapshot: undefined,
  });
});

it("retains startup and cleanup failures and retries tracked VM cleanup", async () => {
  const cleanup = new StopFailedError();
  machine.stopFailure = cleanup;
  machine.failures.set("/runner/api/v2/session/restore", {
    mode: "response",
    error: new VmRestoreError(),
  });
  const manager = new SessionManager({
    backend: backend(),
    store: {
      load: async () => ({ ...session, checkpoint: true }),
      save: async () => {},
      list: async () => [session.runtimeId],
    },
    userId: session.userId,
    idleMs: 1000,
    retentionMs: 10000,
    now: () => 0,
  });
  await expect(
    manager.acquireCodeRuntime(session.runtimeId),
  ).rejects.toStrictEqual(
    new VmStartupCleanupError(guestAddress, new VmRestoreError(), cleanup),
  );
  const failed = machine.process?.state;
  machine.stopFailure = undefined;
  await manager.shutdown();
  expect({ failed, process: machine.process?.state }).toStrictEqual({
    failed: "running",
    process: "stopped",
  });
});
