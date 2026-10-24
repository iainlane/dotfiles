import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { stateEntry } from "../src/session.ts";

interface RecordLine {
  type: string;
  [key: string]: unknown;
}
function recordLine(value: unknown): RecordLine {
  if (
    typeof value !== "object" ||
    value === null ||
    !("type" in value) ||
    typeof value.type !== "string"
  ) {
    throw new Error("Expected an RPC record with a type");
  }
  return { ...value, type: value.type };
}
function startLine(value: unknown): Start {
  if (
    typeof value !== "object" ||
    value === null ||
    !("reason" in value) ||
    typeof value.reason !== "string" ||
    !("path" in value) ||
    typeof value.path !== "string" ||
    !("id" in value) ||
    typeof value.id !== "string" ||
    !("file" in value) ||
    typeof value.file !== "string"
  ) {
    throw new Error("Expected a complete planning session trace");
  }
  return {
    reason: value.reason,
    path: value.path,
    id: value.id,
    file: value.file,
  };
}
interface Start {
  reason: string;
  path: string;
  id: string;
  file: string;
}

it("reviews over real RPC, hands off to a fresh runtime and restores plans through resume and fork", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-planning-rpc-"));
  const sdk = dirname(
    fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")),
  );
  const args = [
    "--mode",
    "rpc",
    "--offline",
    "--no-extensions",
    "--no-skills",
    "--no-mcp",
    "--no-context-files",
    "--no-prompt-templates",
    "--session-dir",
    join(cwd, "sessions"),
    "--provider",
    "planning-rpc-fixture",
    "--model",
    "fixture",
    "-e",
    fileURLToPath(import.meta.resolve("pi-subagents")),
    "-e",
    fileURLToPath(new URL("../index.ts", import.meta.url)),
    "-e",
    fileURLToPath(new URL("./fixtures/provider.ts", import.meta.url)),
  ];
  const command = process.env.PI_TEST_HOST ?? process.execPath;
  const child = spawn(
    command,
    process.env.PI_TEST_HOST !== undefined && process.env.PI_TEST_HOST !== ""
      ? args
      : [join(sdk, "bundle/cli.js"), ...args],
    {
      cwd,
      env: {
        ...process.env,
        HOME: cwd,
        PI_CODING_AGENT_DIR: join(cwd, "agent"),
        PI_PLANNING_TRACE: join(cwd, "starts.jsonl"),
        PI_OFFLINE: "1",
      },
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  let output = "";
  let errors = "";
  const records: RecordLine[] = [];
  child.stderr.on("data", (data: Buffer) => {
    errors += data.toString();
  });
  const send = (value: unknown) => {
    child.stdin.write(JSON.stringify(value) + "\n");
  };
  child.stdout.on("data", (data: Buffer) => {
    output += data.toString();
    while (output.includes("\n")) {
      const index = output.indexOf("\n");
      const line = output.slice(0, index);
      output = output.slice(index + 1);
      const record = recordLine(JSON.parse(line));
      records.push(record);
      if (
        record.type === "extension_ui_request" &&
        record.method === "select"
      ) {
        send({
          type: "extension_ui_response",
          id: record.id,
          value: "Approve in a fresh conversation",
        });
      }
    }
  });
  const wait = async (condition: () => boolean) => {
    const limit = Date.now() + 15_000;
    while (!condition()) {
      if (child.exitCode !== null || Date.now() > limit) {
        throw new Error(
          `RPC fixture did not complete: ${errors}\n${JSON.stringify(records)}`,
        );
      }
      // eslint-disable-next-line no-await-in-loop -- Poll the running fixture until it produces the required record.
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 20);
      });
    }
  };
  const commandResult = async (value: Record<string, unknown>, id: string) => {
    send({ ...value, id });
    await wait(() =>
      records.some((entry) => entry.type === "response" && entry.id === id),
    );
    const response = records.find(
      (entry) => entry.type === "response" && entry.id === id,
    );
    if (!response) {
      throw new Error("Expected the requested RPC response");
    }
    expect(response).toMatchObject({ success: true });
    return response;
  };
  try {
    await writeFile(join(cwd, "project.ts"), "original");
    await commandResult(
      {
        type: "prompt",
        message: "Exercise the fixed offline planning fixture.",
      },
      "start",
    );
    await wait(() =>
      JSON.stringify(records).includes("Fresh implementation fixture ready"),
    );
    const starts: Start[] = (await readFile(join(cwd, "starts.jsonl"), "utf8"))
      .trim()
      .split("\n")
      .map((line) => startLine(JSON.parse(line)));
    expect(starts.map(({ reason }) => reason)).toStrictEqual([
      "startup",
      "new",
    ]);
    const source = starts[0];
    const replacement = starts[1];
    if (!source || !replacement) {
      throw new Error("Expected source and replacement sessions");
    }
    expect(replacement.id).not.toBe(source.id);
    const sourceManager = SessionManager.open(source.file);
    expect(
      sourceManager
        .getBranch()
        .findLast(
          (entry) => entry.type === "custom" && entry.customType === stateEntry,
        ),
    ).toMatchObject({ data: { active: true } });
    const next = SessionManager.open(replacement.file);
    expect(next.getHeader()).toMatchObject({ parentSession: source.file });
    expect(JSON.stringify(next.getBranch())).toContain(
      "Implement the reviewed fixture.",
    );
    expect(JSON.stringify(next.getBranch())).toContain(
      `Source conversation: ${source.file}`,
    );
    await commandResult(
      { type: "switch_session", sessionPath: source.file },
      "resume",
    );
    await commandResult(
      { type: "prompt", message: "Try the fixed mutation fixture." },
      "mutation",
    );
    await wait(() =>
      JSON.stringify(records).includes('"toolCallId":"mutation"'),
    );
    expect(await readFile(join(cwd, "project.ts"), "utf8")).toBe("original");
    await wait(
      () => records.filter((entry) => entry.type === "agent_end").length >= 3,
    );
    const user = SessionManager.open(source.file)
      .getBranch()
      .findLast(
        (entry) => entry.type === "message" && entry.message.role === "user",
      );
    if (!user) {
      throw new Error("The resumed fixture did not persist its user message");
    }
    await commandResult(
      { type: "fork", entryId: user.id, position: "at" },
      "fork",
    );
    const allStarts: Start[] = (
      await readFile(join(cwd, "starts.jsonl"), "utf8")
    )
      .trim()
      .split("\n")
      .map((line) => startLine(JSON.parse(line)));
    const fork = allStarts.at(-1);
    if (!fork) {
      throw new Error("Expected the forked session trace");
    }
    expect(fork.reason).toBe("fork");
    expect(fork.path).not.toBe(source.path);
    expect(await readFile(fork.path, "utf8")).toBe(
      await readFile(source.path, "utf8"),
    );
  } finally {
    if (child.exitCode === null) {
      const exited = once(child, "exit");
      child.kill();
      await exited;
    }
    await rm(cwd, { recursive: true, force: true });
  }
}, 45_000);
