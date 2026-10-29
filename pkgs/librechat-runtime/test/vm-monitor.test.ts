import { expect, it } from "vitest";
import { WorkspaceRecoveryError } from "../src/errors.ts";
import {
  saveVmSnapshot,
  stopExistingVm,
  VmMonitorCommandError,
  type MonitorConnection,
} from "../src/vm-monitor.ts";

it.each([
  {
    snapshot: "snapshot failed",
    resume: {},
    error: VmMonitorCommandError,
    persisted: false,
  },
  {
    snapshot: "",
    resume: { error: { class: "GenericError" } },
    error: WorkspaceRecoveryError,
    persisted: true,
  },
])(
  "reports failed snapshot or resume through $error.name",
  async ({ snapshot, resume, error, persisted }) => {
    let connections = 0;
    let saved = false;
    await expect(
      saveVmSnapshot(
        "/monitor",
        async () => {
          saved = true;
        },
        async () => {
          connections += 1;
          const replies =
            connections === 1
              ? [
                  { QMP: {} },
                  { return: {}, id: "qmp_capabilities" },
                  { return: {}, id: "stop" },
                  { return: snapshot, id: "human-monitor-command" },
                ]
              : [
                  { QMP: {} },
                  { return: {}, id: "qmp_capabilities" },
                  { return: {}, ...resume, id: "cont" },
                ];
          return {
            messages: {
              async *[Symbol.asyncIterator]() {
                yield* replies;
              },
            },
            send: () => {},
            close: () => {},
          };
        },
      ),
    ).rejects.toThrow(error);
    expect({ connections, saved }).toStrictEqual({
      connections: 2,
      saved: persisted,
    });
  },
);

it.each([false, true])(
  "resumes the VM after snapshot persistence fails: %s",
  async (fails) => {
    const commands: unknown[] = [];
    const messages: unknown[] = [
      { QMP: {} },
      { return: {}, id: "qmp_capabilities" },
      { return: {}, id: "stop" },
      { return: "", id: "human-monitor-command" },
    ];
    const monitor: MonitorConnection = {
      messages: {
        async *[Symbol.asyncIterator]() {
          yield* messages;
        },
      },
      send: (command) => {
        commands.push(command);
      },
      close: () => {
        commands.push("close");
      },
    };
    const save = async () => {
      commands.push("persist");
      if (fails) {
        throw new Error("disk full");
      }
    };
    let connections = 0;
    const result = saveVmSnapshot("/monitor", save, async () => {
      connections += 1;
      if (connections === 1) {
        return monitor;
      }
      return {
        ...monitor,
        messages: {
          async *[Symbol.asyncIterator]() {
            yield* [
              { QMP: {} },
              { return: {}, id: "qmp_capabilities" },
              { return: {}, id: "cont" },
            ];
          },
        },
      };
    });
    let outcome = "saved";
    try {
      await result;
    } catch (error) {
      if (!(error instanceof Error)) {
        throw error;
      }
      outcome = error.message;
    }
    expect(outcome).toBe(fails ? "disk full" : "saved");
    expect(commands).toStrictEqual([
      { execute: "qmp_capabilities", id: "qmp_capabilities" },
      { execute: "stop", id: "stop" },
      {
        execute: "human-monitor-command",
        arguments: { "command-line": "savevm librechat" },
        id: "human-monitor-command",
      },
      "close",
      "persist",
      { execute: "qmp_capabilities", id: "qmp_capabilities" },
      { execute: "cont", id: "cont" },
      "close",
    ]);
  },
);

it("negotiates QMP before stopping a VM left by a previous controller", async () => {
  const messages: unknown[] = [
    { QMP: {} },
    { return: {}, id: "capabilities" },
    { return: {}, id: "quit" },
  ];

  const commands: unknown[] = [];

  const monitor: MonitorConnection = {
    messages: {
      async *[Symbol.asyncIterator]() {
        yield* messages;
      },
    },
    send: (command) => {
      commands.push(command);
    },
    close: () => {
      commands.push("close");
    },
  };

  await stopExistingVm("/private/monitor", async () => monitor);

  expect(commands).toStrictEqual([
    { execute: "qmp_capabilities", id: "capabilities" },
    { execute: "quit", id: "quit" },
    "close",
  ]);
});

it("leaves recovery blocked when QMP refuses a command", async () => {
  const messages: unknown[] = [
    { QMP: {} },
    { error: { class: "GenericError" }, id: "capabilities" },
  ];

  const commands: unknown[] = [];

  await expect(
    stopExistingVm("/private/monitor", async () => ({
      messages: {
        async *[Symbol.asyncIterator]() {
          yield* messages;
        },
      },
      send: (command) => {
        commands.push(command);
      },
      close: () => {
        commands.push("close");
      },
    })),
  ).rejects.toThrow(VmMonitorCommandError);

  expect(commands).toStrictEqual([
    { execute: "qmp_capabilities", id: "capabilities" },
    "close",
  ]);
});

it("accepts an absent VM without sending a command", async () => {
  await expect(
    stopExistingVm("/private/monitor", async () => null),
  ).resolves.toBeUndefined();
});
