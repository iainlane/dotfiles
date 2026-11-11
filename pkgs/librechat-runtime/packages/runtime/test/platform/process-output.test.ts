import { setTimeout as delay } from "node:timers/promises";
import { afterEach, expect, it, vi } from "vitest";
import {
  NodeProcessRunner,
  type ProcessOutput,
} from "#runtime/platform/processes";

afterEach(() => vi.restoreAllMocks());

class ProcessOutputTimeoutError extends Error {
  constructor() {
    super("The child output was not observed.");
    this.name = "ProcessOutputTimeoutError";
  }
}

async function outputDeadline(): Promise<never> {
  await delay(5000, undefined, { ref: false });
  throw new ProcessOutputTimeoutError();
}

it("routes managed-service output to the injected sink without ambient writes", async () => {
  const stdout = vi.spyOn(process.stdout, "write").mockReturnValue(true);
  const stderr = vi.spyOn(process.stderr, "write").mockReturnValue(true);
  const output: ProcessOutput[] = [];
  const observed = Promise.withResolvers<void>();
  const runner = new NodeProcessRunner({}, (item) => {
    output.push(item);
    if (output.length === 2) {
      observed.resolve();
    }
  });
  const child = await runner.start({
    executable: process.execPath,
    args: [
      "-e",
      'process.stdout.write("output"); process.stderr.write("error"); setInterval(() => {}, 1000);',
    ],
  });
  try {
    await Promise.race([observed.promise, outputDeadline()]);
  } finally {
    await child.stop();
  }
  expect({
    output: output.toSorted((a, b) => a.stream.localeCompare(b.stream)),
    running: child.running(),
    stdout: stdout.mock.calls,
    stderr: stderr.mock.calls,
  }).toStrictEqual({
    output: [
      { executable: process.execPath, stream: "stderr", text: "error" },
      { executable: process.execPath, stream: "stdout", text: "output" },
    ],
    running: false,
    stdout: [],
    stderr: [],
  });
});

it("decodes UTF-8 characters split across pipe chunks", async () => {
  const output: ProcessOutput[] = [];
  const observed = Promise.withResolvers<void>();
  const runner = new NodeProcessRunner({}, (item) => {
    output.push(item);
    observed.resolve();
  });
  const child = await runner.start({
    executable: process.execPath,
    args: [
      "-e",
      "process.stdout.write(Buffer.from([0xc3])); setTimeout(() => process.stdout.write(Buffer.from([0xa9])), 100); setInterval(() => {}, 1000);",
    ],
  });
  try {
    await Promise.race([observed.promise, outputDeadline()]);
  } finally {
    await child.stop();
  }
  expect(output).toStrictEqual([
    { executable: process.execPath, stream: "stdout", text: "é" },
  ]);
});

it("bounds shutdown when a descendant keeps captured pipes open", async () => {
  const observed = Promise.withResolvers<void>();
  let pidText = "";
  const runner = new NodeProcessRunner({}, (item) => {
    pidText += item.text;
    if (pidText.includes("\n")) {
      observed.resolve();
    }
  });
  const child = await runner.start({
    executable: process.execPath,
    args: [
      "-e",
      'const { spawn } = require("node:child_process"); const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: ["ignore", "inherit", "inherit"] }); process.stdout.write(String(child.pid) + "\\n"); setInterval(() => {}, 1000);',
    ],
  });
  try {
    await Promise.race([observed.promise, outputDeadline()]);
    await Promise.race([
      child.stop(),
      (async () => {
        await delay(1500);
        throw new ProcessOutputTimeoutError();
      })(),
    ]);
    expect(child.running()).toBe(false);
  } finally {
    if (pidText.trim().length > 0) {
      process.kill(Number(pidText.trim()), "SIGKILL");
    }
    await child.stop();
  }
}, 10000);
