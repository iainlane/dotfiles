import { expect, it } from "vitest";
import {
  FileServerReadinessError,
  startFileServer,
} from "#runtime/host/file-server";
import type { Command, ManagedProcess } from "#runtime/platform/processes";

interface FileServerProcess {
  port: number;
  url: string | undefined;
  running: boolean;
}

class Host {
  readonly processes: FileServerProcess[] = [];
  private readonly freePorts: Set<number>;
  private readonly blockedPorts: Set<number>;

  constructor(options: { freePorts: number[]; blockedPorts: number[] }) {
    this.freePorts = new Set(options.freePorts);
    this.blockedPorts = new Set(options.blockedPorts);
  }

  readonly allocatePort = async (): Promise<number> => {
    const port = Math.min(...this.freePorts);
    this.freePorts.delete(port);
    return port;
  };

  readonly start = async (command: Command): Promise<ManagedProcess> => {
    const child: FileServerProcess = {
      port: Number(command.environment?.FILE_SERVER_PORT),
      url: command.environment?.FILE_SERVER_URL,
      running: true,
    };
    this.processes.push(child);
    return {
      exited: Promise.resolve(),
      running: () => child.running,
      stop: async () => {
        child.running = false;
      },
    };
  };

  readonly probe = async (port: number): Promise<boolean> =>
    !this.blockedPorts.has(port) &&
    this.processes.some((child) => child.running && child.port === port);
}

function fileServer(port: number) {
  return { port, url: `http://127.0.0.1:${port}`, running: false };
}

it("retries a dynamic port after a failed bind and stops the failed child", async () => {
  const host = new Host({
    freePorts: [40_000, 40_001, 40_002],
    blockedPorts: [40_000],
  });
  const result = await startFileServer(
    {
      command: { executable: "file-server", args: [] },
      port: 0,
      token: "private",
    },
    {
      signal: new AbortController().signal,
      allocatePort: host.allocatePort,
      probe: host.probe,
      pause: async () => {},
      processes: { start: host.start },
    },
  );
  expect({
    port: result.port,
    running: result.process.running(),
    processes: host.processes,
  }).toStrictEqual({
    port: 40_001,
    running: true,
    processes: [fileServer(40_000), { ...fileServer(40_001), running: true }],
  });
});

it.each([0, 31_000])(
  "bounds failures with configured port %i",
  async (port) => {
    const host = new Host({
      freePorts: [40_000, 40_001, 40_002, 40_003],
      blockedPorts: [31_000, 40_000, 40_001, 40_002, 40_003],
    });
    await expect(
      startFileServer(
        {
          command: { executable: "file-server", args: [] },
          port,
          token: "private",
        },
        {
          signal: new AbortController().signal,
          allocatePort: host.allocatePort,
          probe: host.probe,
          pause: async () => {},
          processes: { start: host.start },
        },
      ),
    ).rejects.toStrictEqual(new FileServerReadinessError());
    expect(host.processes).toStrictEqual(
      port === 0
        ? [fileServer(40_000), fileServer(40_001), fileServer(40_002)]
        : [fileServer(port)],
    );
  },
);

it("stops the candidate when shutdown interrupts readiness", async () => {
  const abort = new AbortController();
  const reason = new DOMException("Shutdown", "AbortError");
  const host = new Host({ freePorts: [40_000], blockedPorts: [40_000] });
  await expect(
    startFileServer(
      {
        command: { executable: "file-server", args: [] },
        port: 0,
        token: "private",
      },
      {
        signal: abort.signal,
        allocatePort: host.allocatePort,
        processes: { start: host.start },
        probe: async (port) => {
          abort.abort(reason);
          return host.probe(port);
        },
        pause: async () => {},
      },
    ),
  ).rejects.toBe(reason);
  expect(host.processes).toStrictEqual([fileServer(40_000)]);
});
