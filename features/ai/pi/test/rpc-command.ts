import { parseRecord } from "./protocol.js";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";

const [pi, command, ...args] = process.argv.slice(2);
assert.ok(
  pi !== undefined && pi !== "" && command !== undefined && command !== "",
  "Pass Pi, the command and its arguments",
);
const child = spawn(
  pi,
  ["--mode", "rpc", "--no-session", "--no-context-files", ...args],
  { stdio: ["pipe", "pipe", "inherit"] },
);
const completed = Promise.withResolvers<void>();
const lines = createInterface({ input: child.stdout });
const deadline = (phase: "startup" | "command", milliseconds: number) =>
  setTimeout(
    () => completed.reject(new Error(`The Pi ${phase} probe timed out`)),
    milliseconds,
  );
let timer = deadline("startup", 120_000);
lines.on("line", (line) => {
  process.stdout.write(line + "\n");
  const record = parseRecord(line);
  if (record.type === "extension_error") {
    completed.reject(
      new Error(
        typeof record.error === "string"
          ? record.error
          : "A command extension failed",
      ),
    );
    return;
  }
  if (record.type !== "response") {
    return;
  }
  if (record.success === false) {
    completed.reject(
      new Error(
        typeof record.error === "string"
          ? record.error
          : "The probe command failed",
      ),
    );
    return;
  }
  if (record.id === "ready") {
    clearTimeout(timer);
    timer = deadline("command", 30_000);
    child.stdin.write(
      JSON.stringify({ id: "probe", type: "prompt", message: `/${command}` }) +
        "\n",
    );
    return;
  }
  if (record.id === "probe") {
    child.stdin.write(
      JSON.stringify({ id: "state", type: "get_state" }) + "\n",
    );
    return;
  }
  if (record.id === "state") {
    completed.resolve();
  }
});
child.on("error", (error) => completed.reject(error));
child.on("exit", (code) =>
  completed.reject(new Error(`Pi exited before completing the probe: ${code}`)),
);
child.stdin.write(JSON.stringify({ id: "ready", type: "get_state" }) + "\n");
try {
  await completed.promise;
  const exited = once(child, "exit");
  child.stdin.end();
  const result: unknown[] = await exited;
  const code: unknown = result[0];
  assert.equal(code, 0);
} finally {
  clearTimeout(timer);
  lines.close();
  child.kill();
}
