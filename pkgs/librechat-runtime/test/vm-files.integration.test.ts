import {
  copyFile,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { afterEach, beforeEach, expect, it } from "vitest";
import {
  CheckpointLimitError,
  FileVmStorage,
  VmSnapshotIntegrityError,
} from "../src/vm-files.ts";
import type { Session } from "../src/sessions.ts";

let directory: string;

let storage: FileVmStorage;
let options: ConstructorParameters<typeof FileVmStorage>[0];

const session: Session = {
  runtimeId: `rt_${"a".repeat(40)}`,
  userId: "0123456789abcdef01234567",
  conversationId: null,
  generation: 1,
  lastUsed: 0,
  checkpoint: false,
  expired: false,
  resetReason: "",
  quarantine: null,
};

function body(text: string): ReadableStream<Uint8Array> {
  return new Response(text).body ?? new ReadableStream();
}

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "librechat-vm-test-"));

  const image = join(directory, "base");

  await writeFile(image, "image");

  options = {
    directory: join(directory, "vms"),
    socketDirectory: join(directory, "sockets"),
    uid: process.getuid?.() ?? 0,
    image,
    kernel: image,
    initrd: image,
    init: "/nix/store/test/init",
    checkpointMaxBytes: 64,
    runtime: {
      executable: "/nix/store/qemu/bin/qemu-system-aarch64",
      forwarder: "/nix/store/socat/bin/socat",
      architecture: "aarch64",
      accelerator: "hvf",
      memoryMiB: 4096,
      cpus: 2,
    },
    retainRuntime: async () => {},
    createDisk: async (source, destination) => {
      await copyFile(source, destination);
    },
    stopExistingVm: async () => {},
  };

  storage = new FileVmStorage(options);
  await storage.prepare(session);
});

afterEach(async () => {
  await rm(directory, { recursive: true, force: true });
});

it("preserves the committed checkpoint after an oversized replacement", async () => {
  await storage.saveCheckpoint(session, body("original"));

  await expect(
    storage.saveCheckpoint(session, body("x".repeat(65))),
  ).rejects.toThrow(CheckpointLimitError);

  expect(await new Response(await storage.readCheckpoint(session)).text()).toBe(
    "original",
  );
});

it("keeps only the latest complete archive after committing its pointer", async () => {
  await storage.saveCheckpoint(session, body("first"));

  await storage.saveCheckpoint(session, body("second"));

  const files = await readdir(join(directory, "vms", session.runtimeId));

  expect({
    files: files.toSorted(),
    contents: await new Response(await storage.readCheckpoint(session)).text(),
    image: await readFile(
      join(directory, "vms", session.runtimeId, "root.qcow2"),
      "utf8",
    ),
  }).toStrictEqual({
    files: [
      "boot.json",
      "checkpoint-16367aacb67a4a017c8da8ab95682ccb390863780f7114dda0a0e0c55644c7c4.tar.gz",
      "checkpoint.json",
      "initrd",
      "kernel",
      "root.qcow2",
    ],
    contents: "second",
    image: "image",
  });
});

it("restores the complete disk with its pinned runtime after an upgrade", async () => {
  const disk = join(directory, "vms", session.runtimeId, "root.qcow2");
  await writeFile(disk, "work and nix state");
  await storage.saveSnapshot(session, disk);
  await writeFile(disk, "uncommitted changes");
  storage = new FileVmStorage({
    ...options,
    init: "/nix/store/upgraded/init",
    runtime: {
      ...options.runtime,
      executable: "/nix/store/upgraded/bin/qemu",
      memoryMiB: 8192,
    },
  });
  const boot = await storage.prepare(session, true);
  expect({
    contents: await readFile(disk, "utf8"),
    snapshot: boot.snapshot,
    runtime: boot.runtime,
  }).toStrictEqual({
    contents: "work and nix state",
    snapshot: "librechat",
    runtime: {
      executable: "/nix/store/qemu/bin/qemu-system-aarch64",
      forwarder: "/nix/store/socat/bin/socat",
      architecture: "aarch64",
      accelerator: "hvf",
      memoryMiB: 4096,
      cpus: 2,
    },
  });
});

it.each(["digest", "bytes"])(
  "rejects a snapshot with incorrect %s without replacing the working disk",
  async (field) => {
    const sessionDirectory = join(directory, "vms", session.runtimeId);
    const disk = join(sessionDirectory, "root.qcow2");
    await storage.saveSnapshot(session, disk);
    const pointer = join(sessionDirectory, "snapshot.json");
    const metadata = z
      .object({ digest: z.string(), bytes: z.number() })
      .parse(JSON.parse(await readFile(pointer, "utf8")));
    if (field === "digest") {
      const oldArchive = join(
        sessionDirectory,
        `snapshot-${metadata.digest}.qcow2.gz`,
      );
      metadata.digest = "0".repeat(64);
      await copyFile(
        oldArchive,
        join(sessionDirectory, `snapshot-${metadata.digest}.qcow2.gz`),
      );
    }
    if (field === "bytes") {
      metadata.bytes += 1;
    }
    await writeFile(pointer, JSON.stringify(metadata));
    await writeFile(disk, "working state");
    await expect(storage.prepare(session, true)).rejects.toThrow(
      VmSnapshotIntegrityError,
    );
    expect({
      disk: await readFile(disk, "utf8"),
      temporary: (await readdir(sessionDirectory)).filter((name) =>
        name.endsWith(".tmp"),
      ),
    }).toStrictEqual({ disk: "working state", temporary: [] });
  },
);
