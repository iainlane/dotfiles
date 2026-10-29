export interface VmBootSpecification {
  architecture: "aarch64" | "x86_64";
  accelerator: "hvf" | "kvm";
  kernel: string;
  initrd: string;
  init: string;
  disk: string;
  controlSocket: string;
  monitorSocket: string;
  forwarder: string;
  ironPort: number;
  fileRelayPort: number;
  archiveBrokerPort: number;
  memoryMiB: number;
  cpus: number;
  snapshot?: "librechat";
}

export type VmRuntime = Pick<
  VmBootSpecification,
  "architecture" | "accelerator" | "forwarder" | "memoryMiB" | "cpus"
> & { executable: string };

export class VmForwarderPathError extends Error {
  constructor() {
    super(
      "The VM forwarder must be an absolute executable path without shell metacharacters",
    );

    this.name = "VmForwarderPathError";
  }
}

export class VmSocketLengthError extends Error {
  constructor() {
    super("VM control socket paths must fit the Darwin UNIX socket limit");

    this.name = "VmSocketLengthError";
  }
}

export class VmPortError extends Error {
  constructor() {
    super("VM forwarding ports must be integers between 1 and 65535");

    this.name = "VmPortError";
  }
}

function optionPath(path: string): string {
  return path.replaceAll(",", ",,");
}

export function qemuArguments(specification: VmBootSpecification): string[] {
  if (!/^\/[a-zA-Z0-9/_+.-]+$/u.test(specification.forwarder)) {
    throw new VmForwarderPathError();
  }

  if (
    [specification.controlSocket, specification.monitorSocket].some(
      (path) => Buffer.byteLength(path) >= 104,
    )
  ) {
    throw new VmSocketLengthError();
  }

  const forwards = [
    ["10.0.2.100", 3128, specification.ironPort],
    ["10.0.2.101", 3190, specification.fileRelayPort],
    ["10.0.2.102", 3194, specification.archiveBrokerPort],
  ] as const;

  if (
    forwards.some(
      ([, , port]) => !Number.isInteger(port) || port < 1 || port > 65535,
    )
  ) {
    throw new VmPortError();
  }

  const network = [
    "user,id=network,restrict=on,ipv6=off",
    `hostfwd=unix:${optionPath(specification.controlSocket)}-:8080`,
    ...forwards.map(
      ([address, guestPort, hostPort]) =>
        `guestfwd=tcp:${address}:${guestPort}-cmd:${specification.forwarder} - TCP:127.0.0.1:${hostPort}`,
    ),
  ].join(",");

  const machine = specification.architecture === "aarch64" ? "virt" : "q35";

  const console =
    specification.architecture === "aarch64" ? "ttyAMA0" : "ttyS0";

  return [
    "-machine",
    `${machine},accel=${specification.accelerator}`,
    "-cpu",
    "host",
    "-smp",
    String(specification.cpus),
    "-m",
    String(specification.memoryMiB),
    "-nodefaults",
    "-no-reboot",
    "-display",
    "none",
    "-serial",
    "stdio",
    "-kernel",
    specification.kernel,
    "-initrd",
    specification.initrd,
    "-append",
    `console=${console} init=${specification.init}`,
    "-drive",
    `file=${optionPath(specification.disk)},if=none,id=root,format=qcow2`,
    "-device",
    "virtio-blk-pci,drive=root",
    "-netdev",
    network,
    "-device",
    "virtio-net-pci,netdev=network",
    "-qmp",
    `unix:${optionPath(specification.monitorSocket)},server=on,wait=off`,
    ...(specification.snapshot === undefined
      ? []
      : ["-loadvm", specification.snapshot, "-S"]),
  ];
}
