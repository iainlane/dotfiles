import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import { CheckpointLimitError, FileVmStorage } from "../src/vm-files.ts";
import type { Session } from "../src/sessions.ts";

let directory: string;

let storage: FileVmStorage;

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

  storage = new FileVmStorage({
    directory: join(directory, "vms"),
    socketDirectory: join(directory, "sockets"),
    uid: process.getuid?.() ?? 0,
    image,
    kernel: image,
    initrd: image,
    init: "/nix/store/test/init",
    checkpointMaxBytes: 8,
    stopExistingVm: async () => {},
  });

  await storage.prepare(session);
});

afterEach(async () => {
  await rm(directory, { recursive: true, force: true });
});

it("preserves the committed checkpoint after an oversized replacement", async () => {
  await storage.saveCheckpoint(session, body("original"));

  await expect(
    storage.saveCheckpoint(session, body("too-large-to-commit")),
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
