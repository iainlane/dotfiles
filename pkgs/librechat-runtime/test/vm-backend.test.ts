import { WorkspaceRecoveryError } from "../src/errors.ts";
import { StatusCodes } from "http-status-codes";
import { beforeEach, expect, it } from "vitest";
import {
  QemuBackend,
  VmCheckpointError,
  VmQuiesceError,
  VmRestoreError,
  type VmFiles,
} from "../src/vm-backend.ts";
import type { ManagedProcess, ProcessRunner } from "../src/processes.ts";
import type { SocketFetch } from "../src/http-socket.ts";
import type { Session } from "../src/sessions.ts";

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

let events: string[];

let files: VmFiles;

let processes: ProcessRunner;

let fetch: SocketFetch;

let failedPath: string;

let exit: PromiseWithResolvers<void>;

let onFailure: (session: Session, error: unknown) => Promise<void>;

let onError: (error: unknown) => void;

let delay: (milliseconds: number, signal?: AbortSignal) => Promise<void>;

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
        controller.abort(
          new DOMException(
            "The guest control deadline expired",
            "TimeoutError",
          ),
        );
      }
    }
  }
}

let deadlines: FixtureDeadlines;

function checkpointBody(): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode("checkpoint"));

      controller.close();
    },
  });
}

beforeEach(() => {
  events = [];

  deadlines = new FixtureDeadlines();

  failedPath = "";

  delay = async () => {
    events.push("delay");
  };

  exit = Promise.withResolvers<void>();

  onFailure = async () => {
    events.push("failed");
  };

  onError = () => {
    events.push("recovery-error");
  };

  const process: ManagedProcess = {
    exited: exit.promise,
    running: () => true,
    stop: async () => {
      events.push("stop");

      exit.resolve();
    },
  };

  processes = {
    run: async () => "",
    start: async () => {
      events.push("qemu");

      return process;
    },
  };

  files = {
    prepare: async () => {
      events.push("prepare");

      return {
        disk: "/disk",
        kernel: "/kernel",
        initrd: "/initrd",
        init: "/init",
        controlSocket: "/control",
        monitorSocket: "/monitor",
      };
    },
    readCheckpoint: async () => {
      events.push("read-checkpoint");

      return checkpointBody();
    },
    saveCheckpoint: async (_session, body) => {
      events.push(`save:${await new Response(body).text()}`);
    },
    remove: async () => {
      events.push("remove");
    },
  };

  fetch = async (_socket, request) => {
    const path = new URL(request.url).pathname;

    events.push(path);

    if (path === failedPath) {
      return new Response(null, { status: StatusCodes.INTERNAL_SERVER_ERROR });
    }

    return new Response(path.endsWith("checkpoint") ? checkpointBody() : null);
  };
});

function backend(): QemuBackend {
  return new QemuBackend({
    executable: "/qemu",
    boot: {
      architecture: "aarch64",
      accelerator: "hvf",
      forwarder: "/bin/socat",
      ironPort: 3128,
      fileRelayPort: 3190,
      archiveBrokerPort: 3194,
      memoryMiB: 4096,
      cpus: 2,
    },
    files,
    processes,
    fetch,
    delay,
    timeout: (milliseconds) => deadlines.signal(milliseconds),
    newBootId: () => "boot",
    caCertificate: "public-ca",
    executionPublicKey: "public-execution-key",
    archiveToken: "read-only-broker-token",
    onFailure,
    onError,
  });
}

it.each([
  { path: "/control/bind", elapsed: 90_000 },
  { path: "/control/resume", elapsed: 420_000 },
  { path: "/control/quiesce", elapsed: 125_000 },
])("allows the guest operation budget for $path", async ({ path, elapsed }) => {
  const originalFetch = fetch;

  fetch = async (socket, request) => {
    if (new URL(request.url).pathname === path) {
      deadlines.advance(elapsed);

      request.signal.throwIfAborted();
    }

    return await originalFetch(socket, request);
  };

  const vm = backend();

  const guest = await vm.start(session, false);

  await vm.checkpoint(session, guest);

  expect(events).toStrictEqual([
    "prepare",
    "qemu",
    "/health",
    "/control/bind",
    "/control/resume",
    "/control/quiesce",
    "/runner/api/v2/session/checkpoint",
    "save:checkpoint",
  ]);
});

it("stops a VM when guest startup exceeds its control deadline", async () => {
  const originalFetch = fetch;

  fetch = async (socket, request) => {
    if (new URL(request.url).pathname === "/control/resume") {
      deadlines.advance(600_000);

      request.signal.throwIfAborted();
    }

    return await originalFetch(socket, request);
  };

  await expect(backend().start(session, false)).rejects.toThrow(
    "The guest control deadline expired",
  );

  expect(events).toStrictEqual([
    "prepare",
    "qemu",
    "/health",
    "/control/bind",
    "stop",
  ]);
});

it("restores files before starting MCP processes", async () => {
  await backend().start(session, true);

  expect(events).toStrictEqual([
    "prepare",
    "qemu",
    "/health",
    "/control/bind",
    "read-checkpoint",
    "/runner/api/v2/session/restore",
    "/control/resume",
  ]);
});

it("stops a VM after a failed restore before MCP can read files", async () => {
  failedPath = "/runner/api/v2/session/restore";

  await expect(backend().start(session, true)).rejects.toThrow(VmRestoreError);

  expect(events).toStrictEqual([
    "prepare",
    "qemu",
    "/health",
    "/control/bind",
    "read-checkpoint",
    "/runner/api/v2/session/restore",
    "stop",
  ]);
});

it("quiesces MCP before committing a checkpoint", async () => {
  const vm = backend();

  const guest = await vm.start(session, false);

  events = [];

  await vm.checkpoint(session, guest);

  expect(events).toStrictEqual([
    "/control/quiesce",
    "/runner/api/v2/session/checkpoint",
    "save:checkpoint",
  ]);
});

it("resumes MCP and keeps the VM running after a failed checkpoint", async () => {
  const vm = backend();

  const guest = await vm.start(session, false);

  events = [];

  failedPath = "/runner/api/v2/session/checkpoint";

  await expect(vm.checkpoint(session, guest)).rejects.toThrow(
    VmCheckpointError,
  );

  expect(events).toStrictEqual([
    "/control/quiesce",
    "/runner/api/v2/session/checkpoint",
    "/control/resume",
  ]);
});

it.each(["response", "transport", "body"])(
  "reports a recovery failure when resume fails through %s",
  async (failure) => {
    const vm = backend();

    const guest = await vm.start(session, false);

    events = [];

    const originalFetch = fetch;

    fetch = async (socket, request) => {
      const path = new URL(request.url).pathname;

      if (path === "/control/resume") {
        events.push(path);

        if (failure === "transport") {
          throw new VmCheckpointError();
        }

        if (failure === "body") {
          return new Response(
            new ReadableStream({
              cancel: () => {
                throw new VmCheckpointError();
              },
            }),
          );
        }

        return new Response(null, { status: StatusCodes.SERVICE_UNAVAILABLE });
      }

      return originalFetch(socket, request);
    };

    const failed = backend();

    failedPath = "/runner/api/v2/session/checkpoint";

    await expect(failed.checkpoint(session, guest)).rejects.toThrow(
      WorkspaceRecoveryError,
    );

    expect(events).toStrictEqual([
      "/control/quiesce",
      "/runner/api/v2/session/checkpoint",
      "/control/resume",
    ]);
  },
);

it.each(["response", "transport", "body"])(
  "resumes MCP after quiesce fails through %s",
  async (failure) => {
    const vm = backend();

    const guest = await vm.start(session, false);

    events = [];

    const originalFetch = fetch;

    fetch = async (socket, request) => {
      const path = new URL(request.url).pathname;

      if (path === "/control/quiesce") {
        events.push(path);

        if (failure === "transport") {
          throw new VmQuiesceError();
        }

        if (failure === "body") {
          return new Response(
            new ReadableStream({
              cancel: () => {
                throw new VmQuiesceError();
              },
            }),
          );
        }

        return new Response(null, { status: StatusCodes.SERVICE_UNAVAILABLE });
      }

      return originalFetch(socket, request);
    };

    await expect(backend().checkpoint(session, guest)).rejects.toThrow(
      VmQuiesceError,
    );

    expect(events).toStrictEqual(["/control/quiesce", "/control/resume"]);
  },
);

it.each([
  { stage: "before", expected: [] },
  { stage: "prepare", expected: ["prepare"] },
  { stage: "qemu", expected: ["prepare", "qemu", "stop"] },
  {
    stage: "/control/bind",
    expected: ["prepare", "qemu", "/health", "/control/bind", "stop"],
  },
  {
    stage: "/runner/api/v2/session/restore",
    expected: [
      "prepare",
      "qemu",
      "/health",
      "/control/bind",
      "read-checkpoint",
      "/runner/api/v2/session/restore",
      "stop",
    ],
  },
  {
    stage: "/control/resume",
    expected: [
      "prepare",
      "qemu",
      "/health",
      "/control/bind",
      "read-checkpoint",
      "/runner/api/v2/session/restore",
      "/control/resume",
      "stop",
    ],
  },
])("stops cancelled startup at $stage", async ({ stage, expected }) => {
  const controller = new AbortController();

  const reason = new DOMException("Assignment cancelled", "AbortError");

  const prepare = files.prepare.bind(files);

  files.prepare = async (candidate) => {
    const result = await prepare(candidate);

    if (stage === "prepare") {
      controller.abort(reason);
    }

    return result;
  };

  const start = processes.start.bind(processes);

  processes.start = async (command) => {
    const result = await start(command);

    if (stage === "qemu") {
      controller.abort(reason);
    }

    return result;
  };

  const originalFetch = fetch;

  let requestAborted: boolean | undefined;

  fetch = async (socket, request) => {
    const response = await originalFetch(socket, request);

    if (new URL(request.url).pathname === stage) {
      controller.abort(reason);

      requestAborted = request.signal.aborted;
    }

    return response;
  };

  if (stage === "before") {
    controller.abort(reason);
  }

  await expect(backend().start(session, true, controller.signal)).rejects.toBe(
    reason,
  );

  expect({ events, requestAborted }).toStrictEqual({
    events: expected,
    requestAborted: stage.startsWith("/") ? true : undefined,
  });
});

it.each(["probe", "delay"])(
  "interrupts the readiness %s when startup is cancelled",
  async (stage) => {
    const controller = new AbortController();

    const reason = new DOMException("Assignment cancelled", "AbortError");

    const waiting = Promise.withResolvers<void>();

    const waitForAbort = async (signal?: AbortSignal): Promise<void> => {
      await new Promise<void>((_resolve, reject) => {
        signal?.addEventListener("abort", () => reject(reason), {
          once: true,
        });

        waiting.resolve();
      });
    };

    fetch = async (_socket, request) => {
      events.push(new URL(request.url).pathname);

      if (stage === "probe") {
        await waitForAbort(request.signal);
      }

      return new Response(null, { status: StatusCodes.SERVICE_UNAVAILABLE });
    };

    delay = async (_milliseconds, signal) => {
      events.push("delay");

      await waitForAbort(signal);
    };

    const pending = backend().start(session, false, controller.signal);

    await waiting.promise;

    controller.abort(reason);

    await expect(pending).rejects.toBe(reason);

    expect(events).toStrictEqual([
      "prepare",
      "qemu",
      "/health",
      ...(stage === "delay" ? ["delay"] : []),
      "stop",
    ]);
  },
);

it("reports a rejected VM failure callback without an unhandled rejection", async () => {
  const failure = new VmRestoreError();

  const recoveryError = new WorkspaceRecoveryError();

  let receivedSession: Session | undefined;

  let receivedFailure: unknown;

  let reported: unknown;

  onFailure = async (failedSession, error) => {
    receivedSession = failedSession;

    receivedFailure = error;

    events.push("failed");

    throw recoveryError;
  };

  onError = (error) => {
    reported = error;

    events.push("recovery-error");
  };

  await backend().start(session, false);

  events = [];

  exit.reject(failure);

  await new Promise<void>((resolve) => {
    setImmediate(resolve);
  });

  expect({ receivedSession, receivedFailure, reported, events }).toStrictEqual({
    receivedSession: session,
    receivedFailure: failure,
    reported: recoveryError,
    events: ["failed", "recovery-error"],
  });
});
