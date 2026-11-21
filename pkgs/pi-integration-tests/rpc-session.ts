import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { type Static, Type } from "typebox";
import { Check } from "typebox/value";
import { parseRecord } from "./protocol.js";

const responseSchema = Type.Object({
  type: Type.String(),
  id: Type.Optional(Type.String()),
  success: Type.Optional(Type.Boolean()),
  error: Type.Optional(Type.String()),
  data: Type.Optional(Type.Unknown()),
});
type RpcRecord = Static<typeof responseSchema>;
const promptResponse = Type.Object({ disposition: Type.String() });
type ExpectedRun = "none" | "prompt" | "command";

function checkResponse(record: RpcRecord): void {
  if (record.type === "response") {
    assert.equal(record.success, true, record.error ?? "Pi RPC failed");
  }
}

interface RpcSession {
  request(command: Record<string, unknown>, id?: string): Promise<unknown>;
  runTurn(message: string): Promise<void>;
  runCommandTurn(command: string): Promise<void>;
}

async function waitForExit(child: ChildProcess): Promise<unknown> {
  try {
    const result: unknown[] = await once(child, "close");
    return result[0];
  } catch (error) {
    return error;
  }
}

export async function withPiRpc<T>(
  pi: string,
  args: readonly string[],
  run: (session: RpcSession) => Promise<T>,
  env: NodeJS.ProcessEnv = process.env,
): Promise<T> {
  const child = spawn(pi, ["--mode", "rpc", "--no-context-files", ...args], {
    env,
    stdio: ["pipe", "pipe", "inherit"],
  });
  const closed = waitForExit(child);
  const lines = createInterface({ input: child.stdout });
  async function* readRecords() {
    for await (const line of lines) {
      process.stdout.write(line + "\n");
      const record = parseRecord(line);
      assert.ok(Check(responseSchema, record), "Expected a Pi RPC record");
      assert.notEqual(
        record.type,
        "extension_error",
        record.error ?? "An extension failed",
      );
      yield record;
    }
  }

  const reader = readRecords();
  // A reply ends the current read without closing stdout for the next command.
  const output = {
    [Symbol.asyncIterator]: () => ({ next: () => reader.next() }),
  };
  let sequence = 0;

  async function send(
    command: Record<string, unknown>,
    id: string,
    expectedRun: ExpectedRun,
  ): Promise<unknown> {
    child.stdin.write(JSON.stringify({ ...command, id }) + "\n");
    let response: RpcRecord | undefined;
    let settled = expectedRun === "none";
    for await (const record of output) {
      checkResponse(record);
      if (record.type === "agent_settled") {
        settled = true;
      }
      if (record.type === "response" && record.id === id) {
        if (command.type === "prompt" && Check(promptResponse, record.data)) {
          if (expectedRun === "none") {
            assert.notEqual(
              record.data.disposition,
              "started",
              "Use runTurn for prompts that start a turn",
            );
          }
          if (expectedRun === "prompt") {
            assert.equal(
              record.data.disposition,
              "started",
              "Pi consumed the prompt without starting a turn",
            );
          }
        }
        response = record;
      }
      if (response !== undefined && settled) {
        return response.data;
      }
    }
    throw new Error(`Pi exited before completing RPC ${id}`, {
      cause: await closed,
    });
  }

  try {
    const result = await run({
      request: (command, id = `probe-${++sequence}`) =>
        send(command, id, "none"),
      async runTurn(message) {
        await send(
          { type: "prompt", message },
          `probe-${++sequence}`,
          "prompt",
        );
      },
      async runCommandTurn(command) {
        await send(
          { type: "prompt", message: `/${command}` },
          `probe-${++sequence}`,
          "command",
        );
      },
    });
    child.stdin.end();
    // Shutdown can emit extension errors after the last response.
    for await (const record of output) {
      checkResponse(record);
    }
    const code = await closed;
    assert.equal(code, 0);
    return result;
  } finally {
    lines.close();
    await reader.return(undefined);
    child.kill();
  }
}
