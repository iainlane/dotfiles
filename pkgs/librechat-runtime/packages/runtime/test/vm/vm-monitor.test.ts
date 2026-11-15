import { expect, it } from "vitest";
import { WorkspaceRecoveryError } from "#runtime/platform/errors";
import {
  saveVmSnapshot,
  stopExistingVm,
  VmMonitorCommandError,
  type MonitorConnection,
} from "#runtime/vm/vm-monitor";

class MonitorBusyError extends Error {
  constructor() {
    super("The QMP socket already has a client");
    this.name = "MonitorBusyError";
  }
}

class RunningDiskError extends Error {
  constructor() {
    super("The VM disk changes while the VM is running");
    this.name = "RunningDiskError";
  }
}

class DiskFullError extends Error {
  constructor() {
    super("disk full");
    this.name = "DiskFullError";
  }
}

type MonitorCommand = Parameters<MonitorConnection["send"]>[0];

class MessageStream implements AsyncIterable<unknown> {
  private readonly buffered: unknown[] = [];
  private ended = false;
  private arrival: PromiseWithResolvers<void> | undefined;

  push(message: unknown): void {
    this.buffered.push(message);
    this.arrival?.resolve();
  }

  end(): void {
    this.ended = true;
    this.arrival?.resolve();
  }

  [Symbol.asyncIterator](): AsyncIterator<unknown> {
    return { next: async () => await this.next() };
  }

  private async next(): Promise<IteratorResult<unknown>> {
    if (this.buffered.length > 0) {
      return { done: false, value: this.buffered.shift() };
    }

    if (this.ended) {
      return { done: true, value: undefined };
    }

    this.arrival = Promise.withResolvers();
    await this.arrival.promise;
    return await this.next();
  }
}

class FakeQemu {
  running = true;
  exited = false;
  snapshots: string[] = [];
  private client: MessageStream | undefined;
  private readonly refused: ReadonlySet<string>;
  private readonly savevmOutput: string;

  constructor(
    options: { refused?: readonly string[]; savevmOutput?: string } = {},
  ) {
    this.refused = new Set(options.refused);
    this.savevmOutput = options.savevmOutput ?? "";
  }

  get connected(): boolean {
    return this.client !== undefined;
  }

  readonly connect = async (): Promise<MonitorConnection | null> => {
    if (this.exited) {
      return null;
    }

    if (this.client !== undefined) {
      throw new MonitorBusyError();
    }

    const messages = new MessageStream();
    this.client = messages;
    messages.push({ QMP: {} });
    let negotiated = false;

    return {
      messages,
      send: (command) => {
        if (!negotiated && command.execute !== "qmp_capabilities") {
          messages.push({
            error: { class: "CommandNotFound" },
            id: command.id,
          });
          return;
        }

        negotiated = true;
        messages.push(this.execute(command));

        if (command.execute === "quit") {
          messages.end();
        }
      },
      close: () => {
        messages.end();

        if (this.client === messages) {
          this.client = undefined;
        }
      },
    };
  };

  private execute(command: MonitorCommand): unknown {
    if (this.refused.has(command.execute)) {
      return { error: { class: "GenericError" }, id: command.id };
    }

    switch (command.execute) {
      case "qmp_capabilities":
        return { return: {}, id: command.id };
      case "stop":
        this.running = false;
        return { return: {}, id: command.id };
      case "cont":
        this.running = true;
        return { return: {}, id: command.id };
      case "quit":
        this.running = false;
        this.exited = true;
        return { return: {}, id: command.id };
      case "human-monitor-command":
        if (command.arguments?.["command-line"] !== "savevm librechat") {
          return { error: { class: "GenericError" }, id: command.id };
        }

        if (this.savevmOutput === "") {
          this.snapshots.push("librechat");
        }

        return { return: this.savevmOutput, id: command.id };
    }

    return { error: { class: "CommandNotFound" }, id: command.id };
  }
}

class SnapshotArchive {
  saved: string[] = [];
  private readonly vm: FakeQemu;
  private readonly failure: Error | undefined;

  constructor(vm: FakeQemu, failure?: Error) {
    this.vm = vm;
    this.failure = failure;
  }

  readonly persist = async (): Promise<void> => {
    if (this.vm.running) {
      throw new RunningDiskError();
    }

    if (this.failure !== undefined) {
      throw this.failure;
    }

    this.saved = [...this.vm.snapshots];
  };
}

it.each([
  {
    vm: { savevmOutput: "snapshot failed" },
    error: new VmMonitorCommandError("snapshot failed"),
    state: { running: true, saved: [] },
  },
  {
    vm: { refused: ["cont"] },
    error: new WorkspaceRecoveryError({
      cause: new VmMonitorCommandError({ class: "GenericError" }),
    }),
    state: { running: false, saved: ["librechat"] },
  },
])(
  "reports failed snapshot or resume through $error.name",
  async ({ vm: options, error, state }) => {
    const vm = new FakeQemu(options);
    const archive = new SnapshotArchive(vm);

    await expect(
      saveVmSnapshot("/monitor", archive.persist, vm.connect),
    ).rejects.toStrictEqual(error);

    expect({
      running: vm.running,
      saved: archive.saved,
      connected: vm.connected,
    }).toStrictEqual({ ...state, connected: false });
  },
);

it("stops the VM, saves and persists its snapshot, then resumes it", async () => {
  const vm = new FakeQemu();
  const archive = new SnapshotArchive(vm);

  await saveVmSnapshot("/monitor", archive.persist, vm.connect);

  expect({
    running: vm.running,
    snapshots: vm.snapshots,
    saved: archive.saved,
    connected: vm.connected,
  }).toStrictEqual({
    running: true,
    snapshots: ["librechat"],
    saved: ["librechat"],
    connected: false,
  });
});

it("resumes the VM after snapshot persistence fails", async () => {
  const vm = new FakeQemu();
  const archive = new SnapshotArchive(vm, new DiskFullError());

  await expect(
    saveVmSnapshot("/monitor", archive.persist, vm.connect),
  ).rejects.toStrictEqual(new DiskFullError());

  expect({
    running: vm.running,
    saved: archive.saved,
    connected: vm.connected,
  }).toStrictEqual({ running: true, saved: [], connected: false });
});

it("negotiates QMP before stopping a VM left by a previous controller", async () => {
  const vm = new FakeQemu();

  await stopExistingVm("/private/monitor", vm.connect);

  expect({
    exited: vm.exited,
    connected: vm.connected,
  }).toStrictEqual({ exited: true, connected: false });
});

it("leaves recovery blocked when QMP refuses a command", async () => {
  const vm = new FakeQemu({ refused: ["qmp_capabilities"] });

  await expect(
    stopExistingVm("/private/monitor", vm.connect),
  ).rejects.toStrictEqual(new VmMonitorCommandError());

  expect({
    exited: vm.exited,
    connected: vm.connected,
  }).toStrictEqual({ exited: false, connected: false });
});

it("accepts an absent VM without sending a command", async () => {
  await expect(
    stopExistingVm("/private/monitor", async () => null),
  ).resolves.toBeUndefined();
});
