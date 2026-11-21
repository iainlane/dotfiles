import assert from "node:assert/strict";
import { withPiRpc } from "./rpc-session.js";

const [pi, command, ...args] = process.argv.slice(2);
assert.ok(
  pi !== undefined && pi !== "" && command !== undefined && command !== "",
  "Pass Pi, the command and its arguments",
);

await withPiRpc(pi, args, async (session) => {
  await session.request({ type: "get_state" }, "ready");
  await session.request({ type: "prompt", message: `/${command}` }, "probe");
  await session.request({ type: "get_state" }, "state");
});
