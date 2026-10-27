import { expect, it } from "vitest";
import {
  stopExistingVm,
  VmMonitorCommandError,
  type MonitorConnection,
} from "../src/vm-monitor.ts";

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
