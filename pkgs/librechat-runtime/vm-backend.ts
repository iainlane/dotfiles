import { WorkspaceRecoveryError } from "./errors.ts";
import type { SocketFetch } from "./http-socket.ts";
import { qemuArguments, type VmBootSpecification } from "./qemu.ts";
import type { ManagedProcess, ProcessRunner } from "./processes.ts";
import type { Guest, GuestBackend, Session } from "./sessions.ts";

const controlTimeouts = {
  bind: 120_000,
  resume: 480_000,
  quiesce: 150_000,
};

export interface VmFiles {
  prepare(
    session: Session,
  ): Promise<
    Pick<
      VmBootSpecification,
      "disk" | "kernel" | "initrd" | "init" | "controlSocket" | "monitorSocket"
    >
  >;

  saveCheckpoint(
    session: Session,
    body: ReadableStream<Uint8Array>,
  ): Promise<void>;

  readCheckpoint(session: Session): Promise<ReadableStream<Uint8Array>>;

  remove(session: Session): Promise<void>;
}

interface VmBackendOptions {
  executable: string;
  boot: Omit<
    VmBootSpecification,
    "disk" | "kernel" | "initrd" | "init" | "controlSocket" | "monitorSocket"
  >;
  files: VmFiles;
  processes: ProcessRunner;
  fetch: SocketFetch;

  delay(milliseconds: number, signal?: AbortSignal): Promise<void>;

  timeout(milliseconds: number): AbortSignal;

  newBootId(): string;
  caCertificate: string;
  archiveToken: string;
  executionPublicKey: string;

  onFailure(session: Session, error: unknown): Promise<void>;

  onError(error: unknown): void;
}

export class VmBootError extends Error {
  constructor() {
    super(
      "The conversation VM did not become ready before its startup deadline",
    );

    this.name = "VmBootError";
  }
}

export class VmBindingError extends Error {
  constructor() {
    super("The conversation VM rejected its runtime binding");

    this.name = "VmBindingError";
  }
}

export class VmRestoreError extends Error {
  constructor() {
    super("The conversation workspace checkpoint could not be restored");

    this.name = "VmRestoreError";
  }
}

export class VmMcpStartupError extends Error {
  constructor() {
    super("The conversation MCP servers could not be started");

    this.name = "VmMcpStartupError";
  }
}

export class VmQuiesceError extends Error {
  constructor() {
    super(
      "The conversation MCP processes could not be stopped for checkpointing",
    );

    this.name = "VmQuiesceError";
  }
}

export class VmCheckpointError extends Error {
  constructor() {
    super("The conversation runner did not produce a complete checkpoint");

    this.name = "VmCheckpointError";
  }
}

export class VmProcessMissingError extends Error {
  constructor() {
    super("The controller has no managed process for this VM boot");

    this.name = "VmProcessMissingError";
  }
}

export class QemuBackend implements GuestBackend {
  private readonly options: VmBackendOptions;
  private readonly processes = new Map<string, ManagedProcess>();

  constructor(options: VmBackendOptions) {
    this.options = options;
  }

  private async ready(
    socket: string,
    process: ManagedProcess,
    signal: AbortSignal,
    remaining = 120,
  ): Promise<void> {
    signal.throwIfAborted();

    if (!process.running() || remaining === 0) {
      throw new VmBootError();
    }

    const response = await this.options
      .fetch(
        socket,
        new Request("http://guest/health", {
          signal: AbortSignal.any([signal, this.options.timeout(1000)]),
        }),
      )
      .catch(() => {
        signal.throwIfAborted();

        return null;
      });

    if (response !== null) {
      await response.body?.cancel();

      signal.throwIfAborted();

      if (response.ok) {
        return;
      }
    }

    await this.options.delay(1000, signal);

    await this.ready(socket, process, signal, remaining - 1);
  }

  private async control(
    guest: Guest,
    path: keyof typeof controlTimeouts,
    payload: unknown = {},
    signal?: AbortSignal,
  ): Promise<Response> {
    const deadline = this.options.timeout(controlTimeouts[path]);

    return await this.options.fetch(
      guest.socket,
      new Request(`http://guest/control/${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        signal:
          signal === undefined ? deadline : AbortSignal.any([signal, deadline]),
      }),
    );
  }

  async start(
    session: Session,
    restore: boolean,
    signal?: AbortSignal,
  ): Promise<Guest> {
    const startupSignal = signal ?? new AbortController().signal;

    startupSignal.throwIfAborted();

    const paths = await this.options.files.prepare(session);

    startupSignal.throwIfAborted();

    const process = await this.options.processes.start({
      executable: this.options.executable,
      args: qemuArguments({ ...this.options.boot, ...paths }),
    });

    const guest: Guest = {
      socket: paths.controlSocket,
      bootId: this.options.newBootId(),
    };

    this.processes.set(guest.bootId, process);

    try {
      startupSignal.throwIfAborted();

      await this.ready(guest.socket, process, startupSignal);

      const binding = await this.control(
        guest,
        "bind",
        {
          runtimeId: session.runtimeId,
          caCertificate: this.options.caCertificate,
          archiveToken: this.options.archiveToken,
          executionPublicKey: this.options.executionPublicKey,
        },
        startupSignal,
      );

      await binding.body?.cancel();

      startupSignal.throwIfAborted();

      if (!binding.ok) {
        throw new VmBindingError();
      }

      if (restore) {
        const body = await this.options.files.readCheckpoint(session);

        const init: RequestInit & { duplex: "half" } = {
          method: "POST",
          body,
          duplex: "half",
          headers: { "x-runtime-session-id": session.runtimeId },
          signal: AbortSignal.any([
            startupSignal,
            this.options.timeout(120_000),
          ]),
        };

        const restored = await this.options.fetch(
          guest.socket,
          new Request("http://guest/runner/api/v2/session/restore", init),
        );

        await restored.body?.cancel();

        startupSignal.throwIfAborted();

        if (!restored.ok) {
          throw new VmRestoreError();
        }
      }

      const mcp = await this.control(guest, "resume", {}, startupSignal);

      await mcp.body?.cancel();

      startupSignal.throwIfAborted();

      if (!mcp.ok) {
        throw new VmMcpStartupError();
      }

      process.exited
        .catch(async (error: unknown) => {
          await this.options.onFailure(session, error);
        })
        .catch((error: unknown) => this.options.onError(error));

      return guest;
    } catch (error) {
      await process.stop();

      this.processes.delete(guest.bootId);

      startupSignal.throwIfAborted();

      throw error;
    }
  }

  async checkpoint(session: Session, guest: Guest): Promise<void> {
    try {
      const quiesced = await this.control(guest, "quiesce");

      await quiesced.body?.cancel();

      if (!quiesced.ok) {
        throw new VmQuiesceError();
      }

      const response = await this.options.fetch(
        guest.socket,
        new Request("http://guest/runner/api/v2/session/checkpoint", {
          headers: { "x-runtime-session-id": session.runtimeId },
          signal: this.options.timeout(120_000),
        }),
      );

      if (!response.ok || response.body === null) {
        await response.body?.cancel();

        throw new VmCheckpointError();
      }

      await this.options.files.saveCheckpoint(session, response.body);
    } catch (error) {
      let resumed: Response;

      try {
        resumed = await this.control(guest, "resume");

        await resumed.body?.cancel();
      } catch (cause) {
        throw new WorkspaceRecoveryError({ cause });
      }

      if (!resumed.ok) {
        throw new WorkspaceRecoveryError();
      }

      throw error;
    }
  }

  async stop(_session: Session, guest: Guest): Promise<void> {
    const process = this.processes.get(guest.bootId);

    if (process === undefined) {
      throw new VmProcessMissingError();
    }

    await process.stop();

    this.processes.delete(guest.bootId);
  }

  async remove(session: Session): Promise<void> {
    await this.options.files.remove(session);
  }
}
