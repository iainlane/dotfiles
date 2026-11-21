import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { parseRecord } from "./protocol.js";
import { withPiRpc } from "./rpc-session.js";

const [pi, model, agentDir] = process.argv.slice(2);
assert.ok(
  pi !== undefined && model !== undefined && agentDir !== undefined,
  "Pass Pi, the configured OpenAI model and the agent directory",
);

const window = 510_000;
await writeFile(
  join(agentDir, "openai-context-cache.json"),
  JSON.stringify({
    grant: createHash("sha256").update("fixture").digest("hex"),
    refreshAfter: Date.now() + 60_000,
    contextWindows: { [model]: window },
  }),
  { mode: 0o600 },
);

const fixture = fileURLToPath(
  new URL("./openai-context-profile-fixture.js", import.meta.url),
);
const settingsPath = join(agentDir, "settings.json");
const settings = parseRecord(await readFile(settingsPath, "utf8"));
const extensions = settings.extensions ?? [];
assert.ok(Check(Type.Array(Type.String()), extensions));
// Pi loads command-line fixtures before the managed extensions.
const fixtureSettings = join(agentDir, "profile-probe-settings.json");
await writeFile(
  fixtureSettings,
  JSON.stringify({ ...settings, extensions: [...extensions, fixture] }),
);
await rename(fixtureSettings, settingsPath);

await withPiRpc(
  pi,
  [
    "--no-session",
    "--no-mcp",
    "--no-skills",
    "--model",
    `openai/${model}`,
    "--offline",
  ],
  async (session) => {
    const ready = await session.request({ type: "get_state" });
    assert.ok(
      Check(
        Type.Object({ model: Type.Object({ contextWindow: Type.Integer() }) }),
        ready,
      ),
    );
    assert.equal(ready.model.contextWindow, window);
    const result = await session.request({
      type: "prompt",
      message: "Check managed startup",
    });
    assert.deepEqual(result, { disposition: "handled" });
  },
);
