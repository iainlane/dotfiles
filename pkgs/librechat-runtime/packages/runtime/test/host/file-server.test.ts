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
  private readonly processes: FileServerProcess[] = [];
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

  running(): { port: number; url: string | undefined }[] {
    return this.processes
      .filter((child) => child.running)
      .map(({ port, url }) => ({ port, url }));
  }
}

function fileServer(port: number) {
  return { port, url: `http://127.0.0.1:${port}` };
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
    processes: host.running(),
  }).toStrictEqual({
    port: 40_001,
    running: true,
    processes: [fileServer(40_001)],
  });
});

async function outcome(
  start: Promise<{ process: ManagedProcess; port: number }>,
): Promise<unknown> {
  try {
    return { port: (await start).port };
  } catch (error) {
    return error;
  }
}

it.each([
  {
    port: 0,
    blockedPorts: [40_000, 40_001],
    result: { port: 40_002 },
    running: [fileServer(40_002)],
  },
  {
    port: 0,
    blockedPorts: [40_000, 40_001, 40_002],
    result: new FileServerReadinessError(),
    running: [],
  },
  {
    port: 31_000,
    blockedPorts: [31_000],
    result: new FileServerReadinessError(),
    running: [],
  },
])(
  "bounds failures with configured port $port and blocked ports $blockedPorts",
  async ({ port, blockedPorts, result: expected, running }) => {
    const host = new Host({
      freePorts: [40_000, 40_001, 40_002, 40_003],
      blockedPorts,
    });
    const result = await outcome(
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
    );
    expect({ result, running: host.running() }).toStrictEqual({
      result: expected,
      running,
    });
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
  expect(host.running()).toStrictEqual([]);
});
