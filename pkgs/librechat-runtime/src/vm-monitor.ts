import { once } from "node:events";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";
import { z } from "zod";
import { WorkspaceRecoveryError } from "./errors.ts";

interface MonitorCommand {
  execute: string;
  id: string;
  arguments?: Record<string, unknown>;
}

export interface MonitorConnection {
  messages: AsyncIterable<unknown>;

  send(command: MonitorCommand): void;

  close(): void;
}

type MonitorConnector = (
  socket: string,
  signal?: AbortSignal,
) => Promise<MonitorConnection | null>;

export class VmMonitorUnavailableError extends Error {
  constructor() {
    super("The private VM monitor is not listening");
    this.name = "VmMonitorUnavailableError";
  }
}

export class VmMonitorGreetingError extends Error {
  constructor() {
    super("The private VM monitor did not send a QMP greeting");

    this.name = "VmMonitorGreetingError";
  }
}

export class VmMonitorCommandError extends Error {
  constructor(cause?: unknown) {
    super(
      "The private VM monitor rejected a command; keep the VM files for inspection",
      { cause },
    );

    this.name = "VmMonitorCommandError";
  }
}

async function connectMonitor(
  path: string,
  signal?: AbortSignal,
): Promise<MonitorConnection | null> {
  const socket = createConnection({
    path,
    signal: AbortSignal.any([
      AbortSignal.timeout(120_000),
      ...(signal === undefined ? [] : [signal]),
    ]),
  });

  const lines = createInterface({ input: socket });

  const iterator = lines[Symbol.asyncIterator]();

  let failure: Error | undefined;

  socket.on("error", (error) => {
    failure = error;

    lines.close();
  });

  try {
    await once(socket, "connect");
  } catch (error) {
    lines.close();

    socket.destroy();

    if (
      error instanceof Error &&
      "code" in error &&
      ["ENOENT", "ECONNREFUSED"].includes(String(error.code))
    ) {
      return null;
    }

    throw error;
  }

  return {
    messages: {
      [Symbol.asyncIterator]: () => ({
        next: async () => {
          const line = await iterator.next();

          if (failure !== undefined) {
            throw failure;
          }

          if (line.done === true) {
            return { done: true, value: undefined };
          }

          const value: unknown = JSON.parse(line.value);

          return { done: false, value };
        },
      }),
    },
    send: (command) => {
      socket.write(`${JSON.stringify(command)}\n`);
    },
    close: () => {
      lines.close();

      socket.destroy();
    },
  };
}

const responseSchema = z.object({
  id: z.string().optional(),
  return: z.unknown().optional(),
  error: z.unknown().optional(),
});

class MonitorSession {
  private readonly iterator: AsyncIterator<unknown>;
  private readonly connection: MonitorConnection;

  constructor(connection: MonitorConnection) {
    this.connection = connection;
    this.iterator = connection.messages[Symbol.asyncIterator]();
  }

  async initialise(): Promise<void> {
    const greeting = await this.iterator.next();

    if (
      greeting.done === true ||
      !z.object({ QMP: z.object({}) }).safeParse(greeting.value).success
    ) {
      throw new VmMonitorGreetingError();
    }

    await this.command("qmp_capabilities");
  }

  async command(
    execute: string,
    args?: Record<string, unknown>,
  ): Promise<unknown> {
    this.connection.send({
      execute,
      id: execute,
      ...(args === undefined ? {} : { arguments: args }),
    });

    return await this.response(execute);
  }

  private async response(id: string): Promise<unknown> {
    const next = await this.iterator.next();

    if (next.done === true) {
      throw new VmMonitorCommandError();
    }

    const response = responseSchema.parse(next.value);

    if (response.id !== id) {
      return await this.response(id);
    }

    if (response.error !== undefined) {
      throw new VmMonitorCommandError(response.error);
    }

    return response.return;
  }
}

async function withMonitor<T>(
  socket: string,
  operation: (session: MonitorSession) => Promise<T>,
  connect: MonitorConnector,
  signal?: AbortSignal,
): Promise<T> {
  const connection = await connect(socket, signal);

  if (connection === null) {
    throw new VmMonitorUnavailableError();
  }

  try {
    const session = new MonitorSession(connection);

    await session.initialise();

    return await operation(session);
  } finally {
    connection.close();
  }
}

export async function resumeVm(
  socket: string,
  connect: MonitorConnector = connectMonitor,
  signal?: AbortSignal,
): Promise<void> {
  await withMonitor(
    socket,
    async (session) => {
      await session.command("cont");
    },
    connect,
    signal,
  );
}

export async function saveVmSnapshot(
  socket: string,
  persist: () => Promise<void>,
  connect: MonitorConnector = connectMonitor,
): Promise<void> {
  let outcome: { ok: true } | { ok: false; error: unknown };

  try {
    await withMonitor(
      socket,
      async (session) => {
        await session.command("stop");
        const result = await session.command("human-monitor-command", {
          "command-line": "savevm librechat",
        });
        if (result !== "") {
          throw new VmMonitorCommandError(result);
        }
      },
      connect,
    );
    await persist();
    outcome = { ok: true };
  } catch (error) {
    outcome = { ok: false, error };
  }

  try {
    await resumeVm(socket, connect);
  } catch (cause) {
    throw new WorkspaceRecoveryError({ cause });
  }

  if (!outcome.ok) {
    throw outcome.error;
  }
}

export async function stopExistingVm(
  socket: string,
  connect: MonitorConnector = connectMonitor,
): Promise<void> {
  const monitor = await connect(socket);

  if (monitor === null) {
    return;
  }

  let stage: "greeting" | "capabilities" | "quit" | "finished" = "greeting";

  try {
    for await (const value of monitor.messages) {
      if (stage === "greeting") {
        if (!z.object({ QMP: z.object({}) }).safeParse(value).success) {
          throw new VmMonitorGreetingError();
        }

        monitor.send({ execute: "qmp_capabilities", id: "capabilities" });

        stage = "capabilities";

        continue;
      }

      const response = responseSchema.safeParse(value);

      if (!response.success || response.data.error !== undefined) {
        throw new VmMonitorCommandError();
      }

      if (response.data.id !== stage) {
        continue;
      }

      if (stage === "capabilities") {
        monitor.send({ execute: "quit", id: "quit" });

        stage = "quit";

        continue;
      }

      stage = "finished";
    }

    if (stage !== "finished") {
      throw new VmMonitorCommandError();
    }
  } finally {
    monitor.close();
  }
}
