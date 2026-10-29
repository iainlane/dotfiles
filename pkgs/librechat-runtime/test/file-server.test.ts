import { expect, it } from "vitest";
import { startFileServer } from "../src/file-server.ts";
import type { ManagedProcess, Command } from "../src/processes.ts";

it("retries a dynamic port after a failed bind and stops the failed child", async () => {
  const commands: Command[] = [];
  const stopped: number[] = [];
  let nextPort = 40_000;
  const result = await startFileServer(
    {
      command: { executable: "file-server", args: [] },
      port: 0,
      token: "private",
    },
    {
      signal: new AbortController().signal,
      allocatePort: async () => nextPort++,
      probe: async (port) => port === 40_001,
      pause: async () => {},
      processes: {
        start: async (command) => {
          const index = commands.push(command) - 1;
          return {
            exited: Promise.resolve(),
            running: () => true,
            stop: async () => {
              stopped.push(index);
            },
          };
        },
      },
    },
  );
  expect({ port: result.port, commands, stopped }).toStrictEqual({
    port: 40_001,
    commands: [40_000, 40_001].map((port) => ({
      executable: "file-server",
      args: [],
      environment: {
        FILE_SERVER_PORT: String(port),
        FILE_SERVER_URL: `http://127.0.0.1:${port}`,
      },
    })),
    stopped: [0],
  });
});

it.each([0, 31_000])(
  "bounds failures with configured port %i",
  async (port) => {
    const attempts: number[] = [];
    let nextPort = 40_000;
    let stopped = 0;
    await expect(
      startFileServer(
        {
          command: { executable: "file-server", args: [] },
          port,
          token: "private",
        },
        {
          signal: new AbortController().signal,
          allocatePort: async () => nextPort++,
          probe: async () => false,
          pause: async () => {},
          processes: {
            start: async (command) => {
              attempts.push(Number(command.environment?.FILE_SERVER_PORT));
              return {
                exited: Promise.resolve(),
                running: () => true,
                stop: async () => {
                  stopped += 1;
                },
              };
            },
          },
        },
      ),
    ).rejects.toThrow(
      "The internal LibreChat file server did not become ready",
    );
    expect({ attempts, stopped }).toStrictEqual(
      port === 0
        ? { attempts: [40_000, 40_001, 40_002], stopped: 3 }
        : { attempts: [port], stopped: 1 },
    );
  },
);

it("stops the candidate when shutdown interrupts readiness", async () => {
  const abort = new AbortController();
  let stopped = false;
  const child: ManagedProcess = {
    exited: Promise.resolve(),
    running: () => true,
    stop: async () => {
      stopped = true;
    },
  };
  await expect(
    startFileServer(
      {
        command: { executable: "file-server", args: [] },
        port: 0,
        token: "private",
      },
      {
        signal: abort.signal,
        allocatePort: async () => 40_000,
        processes: { start: async () => child },
        probe: async () => {
          abort.abort();
          return false;
        },
        pause: async () => {},
      },
    ),
  ).rejects.toMatchObject({ name: "AbortError" });
  expect(stopped).toBe(true);
});
