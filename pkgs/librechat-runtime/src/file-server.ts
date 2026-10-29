import { once } from "node:events";
import { createServer } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import { z } from "zod";
import type { Command, ManagedProcess, ProcessRunner } from "./processes.ts";
import { fileServerReady, ReadinessWaiter } from "./startup.ts";

interface FileServerOptions {
  command: Command;
  port: number;
  token: string;
}

interface FileServerDependencies {
  processes: Pick<ProcessRunner, "start">;
  signal: AbortSignal;
  allocatePort?: () => Promise<number>;
  probe?: (port: number, token: string) => Promise<boolean>;
  pause?: () => Promise<void>;
}

export class FileServerReadinessError extends Error {
  constructor() {
    super(
      "The internal LibreChat file server did not become ready; check the file-server log",
    );
    this.name = "FileServerReadinessError";
  }
}

async function allocatePort(): Promise<number> {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    return z.object({ port: z.number() }).parse(server.address()).port;
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }
}

/** Start the private file server and authenticate its listener before use. */
export async function startFileServer(
  options: FileServerOptions,
  dependencies: FileServerDependencies,
): Promise<{ process: ManagedProcess; port: number }> {
  return attemptStart(options, dependencies, options.port === 0 ? 3 : 1);
}

async function attemptStart(
  options: FileServerOptions,
  dependencies: FileServerDependencies,
  remaining: number,
): Promise<{ process: ManagedProcess; port: number }> {
  const { signal } = dependencies;
  signal.throwIfAborted();
  const port =
    options.port || (await (dependencies.allocatePort ?? allocatePort)());
  signal.throwIfAborted();
  const child = await dependencies.processes.start({
    ...options.command,
    environment: {
      ...options.command.environment,
      FILE_SERVER_PORT: String(port),
      FILE_SERVER_URL: `http://127.0.0.1:${port}`,
    },
  });
  const waiter = new ReadinessWaiter({
    signal,
    pause:
      dependencies.pause ??
      (async () => {
        await delay(500, undefined, { signal });
      }),
  });
  const probe =
    dependencies.probe ??
    (async (selectedPort: number, token: string) =>
      fileServerReady(`http://127.0.0.1:${selectedPort}`, { token }));
  try {
    await waiter.wait(
      async () => {
        if (!child.running()) {
          throw new FileServerReadinessError();
        }
        return probe(port, options.token);
      },
      FileServerReadinessError,
      60,
    );
    signal.throwIfAborted();
    return { process: child, port };
  } catch (error) {
    await child.stop();
    signal.throwIfAborted();
    if (!(error instanceof FileServerReadinessError) || remaining === 1) {
      throw error;
    }
    return attemptStart(options, dependencies, remaining - 1);
  }
}
