import { expect, it } from "vitest";
import {
  CommandExecutionError,
  type Command,
  type ManagedProcess,
} from "#runtime/platform/processes";
import { SystemdService } from "#runtime/guest/systemd-service";

const unit = "librechat-mcp.service";

const command: Command = {
  executable: "/fixture/systemctl",
  args: ["stop", unit],
};

class UnsupportedCommandError extends Error {
  constructor() {
    super("The fixture systemd supports only stopping a unit");

    this.name = "UnsupportedCommandError";
  }
}

class FixtureLauncher implements ManagedProcess {
  readonly exited = Promise.withResolvers<void>().promise;
  state: "running" | "exited" | "stopped";

  constructor(running: boolean) {
    this.state = running ? "running" : "exited";
  }

  running(): boolean {
    return this.state === "running";
  }

  async stop(): Promise<void> {
    this.state = "stopped";
  }
}

class FixtureSystemd {
  readonly units = new Map<string, "active" | "inactive">();
  private readonly failure: unknown;

  constructor(installed: boolean, failure?: unknown) {
    if (installed) {
      this.units.set(unit, "active");
    }

    this.failure = failure;
  }

  async run(value: Command): Promise<string> {
    const [action, name] = value.args;

    if (
      value.executable !== command.executable ||
      action !== "stop" ||
      name === undefined
    ) {
      throw new UnsupportedCommandError();
    }

    if (this.failure !== undefined) {
      throw new CommandExecutionError(value, this.failure);
    }

    if (!this.units.has(name)) {
      throw new CommandExecutionError(value, { code: 5 });
    }

    this.units.set(name, "inactive");

    return "";
  }
}

function fixture(options: {
  installed: boolean;
  running: boolean;
  failure?: unknown;
}) {
  const systemd = new FixtureSystemd(options.installed, options.failure);
  const launcher = new FixtureLauncher(options.running);
  const service = new SystemdService(
    { systemctl: command.executable, unit },
    systemd,
  );

  return {
    service,
    launcher,
    state: () => ({
      units: Object.fromEntries(systemd.units),
      launcher: launcher.state,
    }),
  };
}

it.each([true, false])(
  "stops the unit and launcher when the launcher running state is %s",
  async (running) => {
    const { service, launcher, state } = fixture({ installed: true, running });

    await service.stop(launcher);

    expect(state()).toStrictEqual({
      units: { [unit]: "inactive" },
      launcher: "stopped",
    });
  },
);

it.each([true, false])(
  "cleans up an already-collected unit when the launcher running state is %s",
  async (running) => {
    const { service, launcher, state } = fixture({ installed: false, running });

    await service.stop(launcher);

    expect(state()).toStrictEqual({ units: {}, launcher: "stopped" });
  },
);

it.each([{ code: 1 }, { code: "EACCES" }, { signal: "SIGTERM" }])(
  "preserves a systemctl failure: %j",
  async (failure) => {
    const { service, launcher, state } = fixture({
      installed: true,
      running: true,
      failure,
    });

    await expect(service.stop(launcher)).rejects.toStrictEqual(
      new CommandExecutionError(command, failure),
    );

    expect(state()).toStrictEqual({
      units: { [unit]: "active" },
      launcher: "running",
    });
  },
);
