import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { expect, it } from "vitest";
import { z } from "zod";

const execute = promisify(execFile);

const reportSchema = z.object({
  output: z.array(
    z.object({
      executable: z.string(),
      stream: z.enum(["stdout", "stderr"]),
      text: z.string(),
    }),
  ),
  running: z.boolean(),
});

it("routes managed-service output to the injected sink without ambient writes", async () => {
  const directory = await mkdtemp(join(tmpdir(), "librechat-process-output-"));
  const entry = join(directory, "supervisor.mjs");
  const report = join(directory, "report.json");
  await writeFile(
    entry,
    `
      import { writeFile } from "node:fs/promises";
      import { setTimeout as delay } from "node:timers/promises";
      import { NodeProcessRunner } from ${JSON.stringify(import.meta.resolve("#runtime/platform/processes"))};

      const output = [];
      const runner = new NodeProcessRunner({}, (item) => output.push(item));
      const child = await runner.start({
        executable: process.execPath,
        args: ["-e", 'process.stdout.write("output"); process.stderr.write("error"); setInterval(() => {}, 1000);'],
      });
      const deadline = Date.now() + 5000;
      while (output.length < 2 && Date.now() < deadline) {
        await delay(10);
      }
      await child.stop();
      await writeFile(${JSON.stringify(report)}, JSON.stringify({ output, running: child.running() }));
    `,
  );
  try {
    const { stdout, stderr } = await execute(process.execPath, [entry], {
      timeout: 10_000,
    });
    const result = reportSchema.parse(
      JSON.parse(await readFile(report, "utf8")),
    );
    expect({
      output: result.output.toSorted((a, b) =>
        a.stream.localeCompare(b.stream),
      ),
      running: result.running,
      stdout,
      stderr,
    }).toStrictEqual({
      output: [
        { executable: process.execPath, stream: "stderr", text: "error" },
        { executable: process.execPath, stream: "stdout", text: "output" },
      ],
      running: false,
      stdout: "",
      stderr: "",
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 15_000);
