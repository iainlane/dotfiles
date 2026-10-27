import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { expect, it } from "vitest";
import { z } from "zod";

const execute = promisify(execFile);

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

it.each([
  { code: 0, stdoutClosed: false, status: 0 },
  { code: 1, stdoutClosed: false, status: 1 },
  { code: 0, stdoutClosed: true, status: 1 },
])(
  "flushes output with exit code $code and stdout closed: $stdoutClosed",
  async ({ code, stdoutClosed, status: expectedStatus }) => {
    const directory = await mkdtemp(join(tmpdir(), "librechat-output-"));
    const entry = join(directory, "output.mjs");
    const stdout = stdoutClosed
      ? ""
      : `${"output ".repeat(256 * 1024)}final stdout\n`;
    const stderr = `${"error ".repeat(256 * 1024)}final stderr\n`;

    await writeFile(
      entry,
      `
    import { exitAfterFlushing } from ${JSON.stringify(new URL("../src/cli-output.ts", import.meta.url).href)};

    if (${stdoutClosed}) {
      process.stdout.on("error", () => {});
      process.stdout.end();
    } else {
      process.stdout.write("output ".repeat(256 * 1024) + "final stdout\\n");
    }
    process.stderr.write("error ".repeat(256 * 1024) + "final stderr\\n");
    setInterval(() => {}, 60_000);
    try {
      await exitAfterFlushing(${code});
    } catch {
      process.exitCode = 1;
    }
  `,
    );

    try {
      let status: number | null = 0;
      let output: { stdout: string; stderr: string };

      try {
        output = await execute(process.execPath, [entry], {
          timeout: 10_000,
          maxBuffer: 8 * 1024 * 1024,
        });
      } catch (error) {
        const failure = z
          .object({
            code: z.number().nullable(),
            stdout: z.string(),
            stderr: z.string(),
          })
          .parse(error);
        status = failure.code;
        output = failure;
      }

      expect({
        status,
        stdout: digest(output.stdout),
        stderr: digest(output.stderr),
      }).toStrictEqual({
        status: expectedStatus,
        stdout: digest(stdout),
        stderr: digest(stderr),
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
  15_000,
);

it("runs archive queries without host deployment dependencies", async () => {
  const directory = await mkdtemp(join(tmpdir(), "librechat-cli-"));

  const preload = join(directory, "fetch.mjs");

  const token = "a".repeat(64);

  await writeFile(
    preload,
    `globalThis.fetch = async (url, options) => Response.json({
      url,
      headers: options.headers,
      query: JSON.parse(options.body),
    });`,
  );

  try {
    const { stdout, stderr } = await execute(
      process.execPath,
      [
        "--import",
        pathToFileURL(preload).href,
        fileURLToPath(new URL("../src/cli.ts", import.meta.url)),
        "archive",
        "session",
        "search",
        "concept",
        "--limit",
        "1",
      ],
      { env: { AGENTSVIEW_BROKER_TOKEN: token } },
    );

    const response: unknown = JSON.parse(stdout);

    expect({ response, stderr }).toStrictEqual({
      response: {
        url: "http://10.0.2.102:3194/query",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        query: ["session", "search", "--json", "--limit", "1", "--", "concept"],
      },
      stderr: "",
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
