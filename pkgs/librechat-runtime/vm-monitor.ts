import { once } from "node:events";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";
import { z } from "zod";

export interface MonitorConnection {
  messages: AsyncIterable<unknown>;

  send(command: { execute: string; id: string }): void;

  close(): void;
}

type MonitorConnector = (socket: string) => Promise<MonitorConnection | null>;

export class VmMonitorGreetingError extends Error {
  constructor() {
    super("The private VM monitor did not send a QMP greeting");

    this.name = "VmMonitorGreetingError";
  }
}

export class VmMonitorCommandError extends Error {
  constructor() {
    super(
      "The private VM monitor refused recovery; keep the VM files for inspection",
    );

    this.name = "VmMonitorCommandError";
  }
}

async function connectMonitor(path: string): Promise<MonitorConnection | null> {
  const socket = createConnection({
    path,
    signal: AbortSignal.timeout(15_000),
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
