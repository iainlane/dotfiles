import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { expect, it } from "vitest";

const execute = promisify(execFile);

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
        fileURLToPath(new URL("./cli.ts", import.meta.url)),
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
