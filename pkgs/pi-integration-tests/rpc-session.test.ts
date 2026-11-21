import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { withPiRpc } from "./rpc-session.js";

async function withFixture(
  ending: string,
  use: (executable: string) => Promise<void>,
  disposition = "started",
): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "pi-rpc-session-"));
  try {
    const executable = join(directory, "pi");
    await writeFile(
      executable,
      `#!${process.execPath}
const readline = require("node:readline");
const input = readline.createInterface({ input: process.stdin });
const write = (record) => console.log(JSON.stringify(record));
input.on("line", (line) => {
  const { id, type } = JSON.parse(line);
  const disposition = ${JSON.stringify(disposition)};
  if (disposition === "started") write({ type: "agent_settled" });
  const data = type === "prompt" ? { disposition } : "reply";
  write({ type: "response", id, success: true, data });
});
input.on("close", () => { ${ending} });
`,
      { mode: 0o700 },
    );
    await use(executable);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

await test("recognises an agent settlement that precedes its prompt response", async () => {
  await withFixture("", async (executable) => {
    await withPiRpc(executable, [], async (session) => {
      await session.runTurn("Probe");
      assert.equal(await session.request({ type: "get_state" }), "reply");
    });
  });
});

await test("reports extension errors between the last response and process exit", async () => {
  await withFixture(
    'write({ type: "extension_error", error: "shutdown failed" });',
    async (executable) => {
      await assert.rejects(
        withPiRpc(executable, [], (session) =>
          session.request({ type: "get_state" }),
        ),
        /shutdown failed/,
      );
    },
  );
});

await test("fails immediately if a typed prompt is consumed", async () => {
  await withFixture(
    "",
    async (executable) => {
      await assert.rejects(
        withPiRpc(executable, [], (session) => session.runTurn("Probe")),
        /consumed the prompt/,
      );
    },
    "handled",
  );
});
