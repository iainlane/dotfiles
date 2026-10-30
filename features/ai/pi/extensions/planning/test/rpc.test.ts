import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { attachedPlanContext } from "../src/prompt.ts";
import { stateEntry } from "../src/session.ts";
import { PlanStore } from "../src/store.ts";
import { nodeFiles } from "../src/node-files.ts";

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
interface Start {
  reason: string;
  path: string;
  id: string;
  file: string;
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
function requestContext(value: unknown, step: number): string[] {
  if (
    typeof value !== "object" ||
    value === null ||
    !("step" in value) ||
    value.step !== step ||
    !("context" in value)
  ) {
    return [];
  }
  const text = JSON.stringify(value.context);
  return text === undefined ? [] : [text];
}

it("clears context in the same native session and preserves the plan through compaction, forks and restart", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-planning-rpc-"));
  await mkdir(join(cwd, "agent"));
  await writeFile(
    join(cwd, "agent/settings.json"),
    JSON.stringify({ compaction: { keepRecentTokens: 0 } }),
  );
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
  const launch = (extraArgs: string[] = [], probe = false) =>
    spawn(
      command,
      process.env.PI_TEST_HOST !== undefined && process.env.PI_TEST_HOST !== ""
        ? [...args, ...extraArgs]
        : [join(sdk, "bundle/cli.js"), ...args, ...extraArgs],
      {
        cwd,
        env: {
          ...process.env,
          HOME: cwd,
          PI_CODING_AGENT_DIR: join(cwd, "agent"),
          PI_PLANNING_TRACE: join(cwd, "starts.jsonl"),
          PI_PLANNING_REQUEST_TRACE: join(cwd, "requests.jsonl"),
          PI_PLANNING_RESUME_PROBE: probe ? "1" : "0",
          PI_OFFLINE: "1",
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
  let child = launch();
  let output = "";
  let errors = "";
  const records: RecordLine[] = [];
  const send = (value: unknown) => {
    child.stdin.write(JSON.stringify(value) + "\n");
  };
  const attachOutput = () => {
    child.stderr.on("data", (data: Buffer) => {
      errors += data.toString();
    });
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
            value: "Approve and clear context",
          });
        }
      }
    });
  };
  attachOutput();
  const wait = async (condition: () => boolean) => {
    const limit = Date.now() + 20_000;
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
  const starts = async () =>
    (await readFile(join(cwd, "starts.jsonl"), "utf8"))
      .trim()
      .split("\n")
      .map((line) => startLine(JSON.parse(line)));
  const request = async (step: number) => {
    const matches = (await readFile(join(cwd, "requests.jsonl"), "utf8"))
      .trim()
      .split("\n")
      .flatMap((line) => requestContext(JSON.parse(line), step));
    const result = matches.at(-1);
    if (result === undefined) {
      throw new Error(`Expected provider request ${step}`);
    }
    return result;
  };
  try {
    await writeFile(join(cwd, "project.ts"), "original");
    await commandResult(
      {
        type: "prompt",
        message: "Plan the fixed fixture. private-exploration-marker",
      },
      "start",
    );
    await wait(() =>
      JSON.stringify(records).includes("Implementation fixture ready"),
    );
    await wait(
      () =>
        records.filter((entry) => entry.type === "agent_settled").length >= 2,
    );
    const initial = await starts();
    expect(initial.map(({ reason }) => reason)).toStrictEqual(["startup"]);
    const source = initial[0];
    if (!source) {
      throw new Error("Expected the original session trace");
    }
    const manager = SessionManager.open(source.file);
    const clear = manager
      .getBranch()
      .findLast((entry) => entry.type === "compaction");
    if (clear?.type !== "compaction") {
      throw new Error("Expected native context clearing");
    }
    expect(clear.firstKeptEntryId).toBe(clear.id);
    expect(manager.getHeader()).toMatchObject({ id: source.id });
    expect(JSON.stringify(manager.getBranch())).toContain(
      "private-exploration-marker",
    );
    expect(
      manager
        .getBranch()
        .findLast(
          (entry) => entry.type === "custom" && entry.customType === stateEntry,
        ),
    ).toMatchObject({ data: { active: false, sourceSessionId: source.id } });
    const implementation = await request(4);
    expect(implementation).toContain("Implement the reviewed fixture.");
    expect(implementation).toContain(source.path);
    expect(implementation).not.toContain("private-exploration-marker");
    expect(implementation).not.toContain("Plan mode is active.");

    const plan = new PlanStore(join(cwd, "agent/plans"), source.id, nodeFiles);
    plan.write("# Updated plan\n\nContinue the remaining implementation.\n");
    await commandResult({ type: "compact" }, "ordinary-compact");
    const compacted = SessionManager.open(source.file);
    expect(
      compacted
        .getBranch()
        .findLast((entry) => entry.type === "custom_message"),
    ).toMatchObject({
      customType: "dotfiles:planning-reminder:v1",
      content: attachedPlanContext(plan.read()),
      display: false,
    });
    await commandResult(
      { type: "prompt", message: "Continue with the attached plan." },
      "after-compact",
    );
    await wait(
      () =>
        records.filter((entry) => entry.type === "agent_settled").length >= 3,
    );
    expect(await request(5)).toContain(
      "Continue the remaining implementation.",
    );
    expect(await request(5)).not.toContain("private-exploration-marker");

    await commandResult({ type: "prompt", message: "/plan" }, "reenter");
    await commandResult(
      { type: "prompt", message: "Continue planning the fixed fixture." },
      "planning-again",
    );
    await wait(
      () =>
        records.filter((entry) => entry.type === "agent_settled").length >= 4,
    );
    const user = SessionManager.open(source.file)
      .getBranch()
      .findLast(
        (entry) => entry.type === "message" && entry.message.role === "user",
      );
    if (!user) {
      throw new Error("Expected a persisted planning prompt");
    }
    await commandResult(
      { type: "fork", entryId: user.id, position: "at" },
      "fork",
    );
    const fork = (await starts()).at(-1);
    if (!fork) {
      throw new Error("Expected the forked session trace");
    }
    expect(fork.reason).toBe("fork");
    expect(fork.path).not.toBe(source.path);
    expect(await readFile(fork.path, "utf8")).toBe(
      await readFile(source.path, "utf8"),
    );

    const expectedPlan = await readFile(source.path, "utf8");
    const restart = async () => {
      const closed = once(child, "close");
      child.kill();
      await closed;
      records.length = 0;
      output = "";
      errors = "";
      child = launch(["--session", source.file], true);
      attachOutput();
    };
    await restart();
    await commandResult(
      { type: "prompt", message: "Probe restored plan restrictions." },
      "process-resume-active",
    );
    await wait(() => records.some((entry) => entry.type === "agent_settled"));
    const activeResume = (await starts()).at(-1);
    expect({
      id: activeResume?.id,
      path: activeResume?.path,
      plan: await readFile(source.path, "utf8"),
      project: await readFile(join(cwd, "project.ts"), "utf8"),
    }).toStrictEqual({
      id: source.id,
      path: source.path,
      plan: expectedPlan,
      project: "original",
    });
    await commandResult({ type: "prompt", message: "/plan" }, "human-exit");
    await restart();
    await commandResult(
      { type: "prompt", message: "Probe restored ordinary mode." },
      "process-resume-inactive",
    );
    await wait(() => records.some((entry) => entry.type === "agent_settled"));
    const inactiveResume = (await starts()).at(-1);
    const restored = SessionManager.open(source.file);
    const notice = restored
      .getBranch()
      .findLast((entry) => entry.type === "custom_message");
    expect({
      id: inactiveResume?.id,
      path: inactiveResume?.path,
      plan: await readFile(source.path, "utf8"),
      project: await readFile(join(cwd, "project.ts"), "utf8"),
    }).toStrictEqual({
      id: source.id,
      path: source.path,
      plan: expectedPlan,
      project: "unapproved",
    });
    expect(notice).toMatchObject({
      customType: "dotfiles:planning-exit:v1",
      display: false,
    });
    if (notice?.type !== "custom_message") {
      throw new Error("Expected the exit reminder");
    }
    expect(notice.content).toContain(source.path);
    expect(
      restored
        .getBranch()
        .findLast(
          (entry) => entry.type === "custom" && entry.customType === stateEntry,
        ),
    ).toMatchObject({
      data: {
        version: 1,
        active: false,
        sourceSessionId: source.id,
        exitReminderPending: false,
      },
    });
  } finally {
    if (child.exitCode === null) {
      const exited = once(child, "exit");
      child.kill();
      await exited;
    }
    await rm(cwd, { recursive: true, force: true });
  }
}, 90_000);
