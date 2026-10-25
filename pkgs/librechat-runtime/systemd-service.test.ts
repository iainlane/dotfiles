import { expect, it } from "vitest";
import {
  CommandExecutionError,
  type Command,
  type ManagedProcess,
} from "./processes.ts";
import { SystemdService } from "./systemd-service.ts";

const command: Command = {
  executable: "/fixture/systemctl",
  args: ["stop", "librechat-mcp.service"],
};

function fixture(cause: unknown, running: boolean) {
  const commands: Command[] = [];
  let stopped = false;
  const error = new CommandExecutionError(command, cause);

  const child: ManagedProcess = {
    exited: Promise.resolve(),
    running: () => running,
    stop: async () => {
      stopped = true;
    },
  };

  const service = new SystemdService(
    { systemctl: command.executable, unit: "librechat-mcp.service" },
    {
      run: async (value) => {
        commands.push(value);

        if (cause !== undefined) {
          throw error;
        }

        return "";
      },
    },
  );

  return { service, child, error, result: () => ({ commands, stopped }) };
}

it.each([true, false])(
  "stops the unit and launcher when the launcher running state is %s",
  async (running) => {
    const { service, child, result } = fixture(undefined, running);

    await service.stop(child);

    expect(result()).toStrictEqual({ commands: [command], stopped: true });
  },
);

it.each([true, false])(
  "cleans up an already-collected unit when the launcher running state is %s",
  async (running) => {
    const { service, child, result } = fixture({ code: 5 }, running);

    await service.stop(child);

    expect(result()).toStrictEqual({ commands: [command], stopped: true });
  },
);

it.each([{ code: 1 }, { code: "EACCES" }, { signal: "SIGTERM" }])(
  "preserves a systemctl failure: %j",
  async (cause) => {
    const { service, child, error, result } = fixture(cause, true);

    await expect(service.stop(child)).rejects.toBe(error);

    expect(result()).toStrictEqual({ commands: [command], stopped: false });
  },
);
