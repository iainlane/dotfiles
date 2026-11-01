import { expect, it } from "vitest";
import {
  qemuArguments,
  VmForwarderPathError,
  VmPortError,
  VmSocketLengthError,
  type VmBootSpecification,
} from "../src/qemu.ts";

const specification: VmBootSpecification = {
  architecture: "aarch64",
  accelerator: "hvf",
  kernel: "/store/kernel",
  initrd: "/store/initrd",
  init: "/store/init",
  disk: "/state/root.qcow2",
  controlSocket: "/tmp/lc/control",
  monitorSocket: "/tmp/lc/monitor",
  forwarder: "/nix/store/forwarder/bin/socat",
  ironPort: 3128,
  fileRelayPort: 3190,
  archiveBrokerPort: 3194,
  memoryMiB: 4096,
  cpus: 2,
};

it("forces guest egress through explicit forwards without host file shares", () => {
  expect(qemuArguments(specification)).toStrictEqual([
    "-machine",
    "virt,accel=hvf",
    "-cpu",
    "host",
    "-smp",
    "2",
    "-m",
    "4096",
    "-nodefaults",
    "-no-reboot",
    "-display",
    "none",
    "-serial",
    "stdio",
    "-kernel",
    "/store/kernel",
    "-initrd",
    "/store/initrd",
    "-append",
    "console=ttyAMA0 init=/store/init",
    "-drive",
    "file=/state/root.qcow2,if=none,id=root,format=qcow2",
    "-device",
    "virtio-blk-pci,drive=root",
    "-netdev",
    "user,id=network,restrict=on,ipv6=off,hostfwd=unix:/tmp/lc/control-:8080,guestfwd=tcp:10.0.2.100:3128-cmd:/nix/store/forwarder/bin/socat - TCP:127.0.0.1:3128,guestfwd=tcp:10.0.2.101:3190-cmd:/nix/store/forwarder/bin/socat - TCP:127.0.0.1:3190,guestfwd=tcp:10.0.2.102:3194-cmd:/nix/store/forwarder/bin/socat - TCP:127.0.0.1:3194",
    "-device",
    "virtio-net-pci,netdev=network",
    "-qmp",
    "unix:/tmp/lc/monitor,server=on,wait=off",
  ]);
});

it.each([
  { accelerator: "hvf", cpu: "host" },
  { accelerator: "kvm", cpu: "host" },
  { accelerator: "tcg", cpu: "max" },
] as const)(
  "selects the $cpu CPU model for $accelerator",
  ({ accelerator, cpu }) => {
    const args = qemuArguments({ ...specification, accelerator });

    expect({
      machine: args.at(args.indexOf("-machine") + 1),
      cpu: args.at(args.indexOf("-cpu") + 1),
    }).toStrictEqual({ machine: `virt,accel=${accelerator}`, cpu });
  },
);

it.each([
  [{ forwarder: "/bin/socat;bad" }, VmForwarderPathError],
  [{ controlSocket: "x".repeat(104) }, VmSocketLengthError],
  [{ ironPort: 0 }, VmPortError],
] as const)(
  "rejects invalid forwarding configuration %j",
  (invalid, errorType) => {
    expect(() => qemuArguments({ ...specification, ...invalid })).toThrow(
      errorType,
    );
  },
);
