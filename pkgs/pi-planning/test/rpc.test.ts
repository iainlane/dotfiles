import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { submitPlanOutputSchema } from "#planning/contracts.ts";
import { displayText } from "#planning/presentation.ts";
import { maxPlanCodeUnits } from "#planning/validation.ts";
import { boundaryText } from "./fixtures/boundary.ts";
import {
  attachedPlanContext,
  implementationContext,
  planExitReminder,
} from "#planning/prompt.ts";
import { stateEntry } from "#planning/session.ts";
import { PlanStore } from "#planning/store.ts";
import { nodeFiles } from "#planning/node-files.ts";

interface RecordLine {
  type: string;
  [key: string]: unknown;
}

/**
 * Waits for records from an RPC child. Call `notify` after each record; it
 * checks every waiting condition. A child whose output closes before the
 * condition is true rejects the wait with `failure()`.
 */
class RecordWaits {
  private readonly checks = new Set<() => void>();

  notify(): void {
    for (const check of this.checks) {
      check();
    }
  }

  until(
    child: ChildProcess,
    condition: () => boolean,
    failure: () => string,
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const settle = (error?: Error) => {
        this.checks.delete(check);
        child.stdout?.off("close", closed);
        if (error === undefined) {
          resolve();
        } else {
          reject(error);
        }
      };
      const check = () => {
        if (condition()) {
          settle();
        }
      };
      const closed = () => {
        settle(condition() ? undefined : new Error(failure()));
      };
      this.checks.add(check);
      child.stdout?.on("close", closed);
      check();
      if (this.checks.has(check) && child.stdout?.closed === true) {
        closed();
      }
    });
  }
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
function rpcResponse(id: string, command: string, data: unknown) {
  return { id, type: "response", command, success: true, data };
}

const sessionStateSchema = Type.Object({
  sessionId: Type.String(),
  sessionFile: Type.String(),
});

/** Asks the RPC child for its current session with `get_state`. */
async function sessionState(
  send: (value: unknown) => void,
  wait: (condition: () => boolean) => Promise<void>,
  records: RecordLine[],
  id: string,
): Promise<{ sessionId: string; sessionFile: string }> {
  const response = () =>
    records.find((record) => record.type === "response" && record.id === id);
  send({ type: "get_state", id });
  await wait(() => response() !== undefined);
  const data = response()?.data;
  if (!Check(sessionStateSchema, data)) {
    throw new Error(`Expected the session state: ${JSON.stringify(data)}`);
  }
  return { sessionId: data.sessionId, sessionFile: data.sessionFile };
}

const requestId: unknown = expect.stringMatching(
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u,
);

/**
 * Summarises the conversation that the session sends to the model: the
 * compaction summaries, custom messages and user and assistant content.
 */
function conversation(manager: SessionManager): unknown[] {
  return manager
    .buildSessionContext()
    .messages.flatMap((message): unknown[] => {
      if (message.role === "compactionSummary") {
        return [{ summary: message.summary }];
      }

      if (message.role === "custom") {
        return [
          {
            custom: message.customType,
            content: message.content,
            display: message.display,
          },
        ];
      }

      if (message.role === "user" || message.role === "assistant") {
        return [{ [message.role]: message.content }];
      }

      return [];
    });
}

type SessionEntry = ReturnType<SessionManager["getBranch"]>[number];

/** The parts of a session entry that the planning extension writes. */
function written(entry: SessionEntry | undefined): unknown {
  if (entry?.type === "custom") {
    return { custom: entry.customType, data: entry.data };
  }

  if (entry?.type === "custom_message") {
    return {
      custom: entry.customType,
      content: entry.content,
      display: entry.display,
    };
  }

  if (entry?.type === "compaction") {
    return {
      compaction: entry.summary,
      selfRetaining: entry.firstKeptEntryId === entry.id,
      details: entry.details,
    };
  }

  return entry;
}

function fixtureReply(text: string) {
  return { assistant: [{ type: "text", text }] };
}

it.each(["controls", "unicode"])(
  "preserves boundary-size plans and feedback through native RPC: %s",
  async (kind) => {
    const cwd = await realpath(
      await mkdtemp(join(tmpdir(), "pi-rpc-boundary-")),
    );
    await mkdir(join(cwd, "agent"));
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
    const nativeHost = process.env.PI_TEST_HOST;
    const useNativeHost = nativeHost !== undefined && nativeHost !== "";
    const child = spawn(
      useNativeHost ? nativeHost : process.execPath,
      useNativeHost ? args : [join(sdk, "bundle/cli.js"), ...args],
      {
        cwd,
        env: {
          ...process.env,
          HOME: cwd,
          PI_CODING_AGENT_DIR: join(cwd, "agent"),
          PI_PLANNING_BOUNDARY_KIND: kind,
          PI_OFFLINE: "1",
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    const feedback = boundaryText(
      "Feedback:\n",
      kind === "unicode" ? "🦉" : "\u0000",
    );
    const records: RecordLine[] = [];
    const waits = new RecordWaits();
    let errors = "";
    const send = (value: unknown) =>
      child.stdin.write(JSON.stringify(value) + "\n");
    child.stderr.on("data", (data: Buffer) => {
      errors += data.toString();
    });
    const output = createInterface({ input: child.stdout });
    output.on("line", (line) => {
      const record = recordLine(JSON.parse(line));
      records.push(record);
      waits.notify();
      if (record.type !== "extension_ui_request") {
        return;
      }
      if (record.method === "confirm") {
        send({ type: "extension_ui_response", id: record.id, confirmed: true });
      }
      if (record.method === "select") {
        send({
          type: "extension_ui_response",
          id: record.id,
          value:
            Array.isArray(record.options) &&
            record.options.includes("Add a comment")
              ? "Add a comment"
              : "No, keep planning",
        });
      }
      if (record.method === "input") {
        send({ type: "extension_ui_response", id: record.id, value: feedback });
      }
    });
    try {
      send({ type: "prompt", message: "Review the boundary fixture." });
      const wait = (condition: () => boolean) =>
        waits.until(
          child,
          condition,
          () => `The native RPC fixture has not settled: ${errors}`,
        );
      await wait(() =>
        records.some((record) => record.type === "agent_settled"),
      );
      const source = await sessionState(send, wait, records, "state");
      const plan = new PlanStore(
        join(cwd, "agent", "plans"),
        source.sessionId,
        nodeFiles,
      ).read();
      const title = `Review plan ${join("~", relative(cwd, plan.path))}\n\n${displayText(plan.content)}`;
      const resultSchema = Type.Object({
        type: Type.Literal("tool_execution_end"),
        toolCallId: Type.Literal("submit"),
        result: Type.Object({ structuredContent: submitPlanOutputSchema }),
      });
      const result = records.find(
        (record) =>
          record.type === "tool_execution_end" &&
          record.toolCallId === "submit",
      );
      if (!Check(resultSchema, result)) {
        throw new Error(
          `Expected a complete structured RPC review result: ${errors}`,
        );
      }
      expect({
        codeUnits: [plan.content.length, feedback.length],
        titles: records
          .filter(
            (record) =>
              record.type === "extension_ui_request" &&
              record.method === "select",
          )
          .map((record) => record.title),
        structured: result.result.structuredContent,
      }).toStrictEqual({
        codeUnits: [maxPlanCodeUnits, maxPlanCodeUnits],
        titles: [title, `${title}\n\nComment: ${displayText(feedback)}`],
        structured: {
          version: 1,
          decision: "revise",
          plan,
          imageCount: 0,
          feedback,
        },
      });
    } finally {
      output.close();
      if (child.exitCode === null) {
        const exited = once(child, "exit");
        child.kill();
        await exited;
      }
      await rm(cwd, { recursive: true, force: true });
    }
  },
);

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
  const launch = (extraArgs: string[] = []) =>
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
          PI_OFFLINE: "1",
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
  let child = launch();
  let output = "";
  let errors = "";
  const records: RecordLine[] = [];
  const waits = new RecordWaits();
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
        waits.notify();
        if (
          record.type === "extension_ui_request" &&
          record.method === "confirm" &&
          record.title === "Enter Plan mode?"
        ) {
          send({
            type: "extension_ui_response",
            id: record.id,
            confirmed: true,
          });
        }
        if (
          record.type === "extension_ui_request" &&
          record.method === "select"
        ) {
          send({
            type: "extension_ui_response",
            id: record.id,
            value: "Yes, clear context",
          });
        }
      }
    });
  };
  attachOutput();
  const wait = (condition: () => boolean) =>
    waits.until(
      child,
      condition,
      () =>
        `RPC fixture did not complete: ${errors}\n${JSON.stringify(records)}`,
    );
  const commandResult = async (value: Record<string, unknown>, id: string) => {
    send({ ...value, id });
    const response = () =>
      records.find((entry) => entry.type === "response" && entry.id === id);
    await wait(() => response() !== undefined);
    return response();
  };
  const prompt = async (message: string, id: string, disposition: string) =>
    expect(await commandResult({ type: "prompt", message }, id)).toStrictEqual(
      rpcResponse(id, "prompt", { disposition }),
    );
  const state = (id: string) => sessionState(send, wait, records, id);
  const settledAfter = (start: (record: RecordLine) => boolean) =>
    wait(() => {
      const index = records.findIndex((record) => start(record));
      return (
        index !== -1 &&
        records.slice(index).some((record) => record.type === "agent_settled")
      );
    });
  const response = (id: string) => (record: RecordLine) =>
    record.type === "response" && record.id === id;
  const plansDirectory = join(cwd, "agent/plans");
  try {
    await writeFile(join(cwd, "project.ts"), "original");
    const source = await state("initial-state");
    await prompt(
      "Plan the fixed fixture. private-exploration-marker",
      "start",
      "started",
    );
    await settledAfter((record) =>
      JSON.stringify(record).includes("Implementation fixture ready"),
    );
    const plan = new PlanStore(plansDirectory, source.sessionId, nodeFiles);
    const approved = plan.read();
    const summary = implementationContext(approved, source.sessionFile);
    const manager = SessionManager.open(source.sessionFile);
    const branch = manager.getBranch();
    const clear = branch.findLast((entry) => entry.type === "compaction");
    if (clear?.type !== "compaction") {
      throw new Error("Expected native context clearing");
    }
    expect({
      session: await state("cleared-state"),
      prompts: branch.flatMap((entry) =>
        entry.type === "message" && entry.message.role === "user"
          ? [entry.message.content]
          : [],
      ),
      clear: written(clear),
      saved: written(
        branch.findLast(
          (entry) => entry.type === "custom" && entry.customType === stateEntry,
        ),
      ),
      conversation: conversation(manager),
    }).toStrictEqual({
      session: source,
      prompts: [
        [
          {
            type: "text",
            text: "Plan the fixed fixture. private-exploration-marker",
          },
        ],
      ],
      clear: {
        compaction: summary,
        selfRetaining: true,
        details: {
          customType: "dotfiles:planning-clear:v1",
          token: requestId,
        },
      },
      saved: {
        custom: stateEntry,
        data: {
          version: 1,
          active: false,
          sourceSessionId: source.sessionId,
          exitReminderPending: false,
        },
      },
      conversation: [
        { summary },
        {
          custom: "dotfiles:planning-implementation:v1",
          content: summary,
          display: false,
        },
        fixtureReply("Implementation fixture ready"),
      ],
    });

    const updated = plan.write(
      "# Updated plan\n\nContinue the remaining implementation.\n",
    );
    await commandResult({ type: "compact" }, "ordinary-compact");
    const compaction = SessionManager.open(source.sessionFile);
    await prompt(
      "Continue with the attached plan.",
      "after-compact",
      "started",
    );
    await settledAfter(response("after-compact"));
    expect({
      reminder: written(
        compaction
          .getBranch()
          .findLast((entry) => entry.type === "custom_message"),
      ),
      conversation: conversation(SessionManager.open(source.sessionFile)),
    }).toStrictEqual({
      reminder: {
        custom: "dotfiles:planning-reminder:v1",
        content: attachedPlanContext(updated),
        display: false,
      },
      conversation: [
        { summary: "Offline compaction fixture." },
        fixtureReply("Implementation fixture ready"),
        {
          custom: "dotfiles:planning-reminder:v1",
          content: attachedPlanContext(updated),
          display: false,
        },
        { user: [{ type: "text", text: "Continue with the attached plan." }] },
        fixtureReply("Fixture finished"),
      ],
    });

    await prompt("/plan", "reenter", "handled");
    await prompt(
      "Continue planning the fixed fixture.",
      "planning-again",
      "started",
    );
    await settledAfter(response("planning-again"));
    const user = SessionManager.open(source.sessionFile)
      .getBranch()
      .findLast(
        (entry) => entry.type === "message" && entry.message.role === "user",
      );
    if (!user) {
      throw new Error("Expected a persisted planning prompt");
    }
    const forked = await commandResult(
      { type: "fork", entryId: user.id, position: "at" },
      "fork",
    );
    const fork = await state("fork-state");
    const expectedPlan = await readFile(plan.path, "utf8");
    expect({
      response: forked,
      newSession: fork.sessionId !== source.sessionId,
      plan: await readFile(
        new PlanStore(plansDirectory, fork.sessionId, nodeFiles).path,
        "utf8",
      ),
    }).toStrictEqual({
      response: rpcResponse("fork", "fork", {
        text: "Continue planning the fixed fixture.",
        cancelled: false,
      }),
      newSession: true,
      plan: expectedPlan,
    });

    const restart = async () => {
      const closed = once(child, "close");
      child.kill();
      await closed;
      records.length = 0;
      output = "";
      errors = "";
      child = launch(["--session", source.sessionFile]);
      attachOutput();
    };
    await restart();
    await prompt(
      "Probe restored plan restrictions.",
      "process-resume-active",
      "started",
    );
    await wait(() => records.some((entry) => entry.type === "agent_settled"));
    expect({
      session: await state("resume-active-state"),
      plan: await readFile(plan.path, "utf8"),
      project: await readFile(join(cwd, "project.ts"), "utf8"),
    }).toStrictEqual({
      session: source,
      plan: expectedPlan,
      project: "original",
    });
    await prompt("/plan exit", "human-exit", "handled");
    await restart();
    await prompt(
      "Probe restored ordinary mode.",
      "process-resume-inactive",
      "started",
    );
    await wait(() => records.some((entry) => entry.type === "agent_settled"));
    const restored = SessionManager.open(source.sessionFile).getBranch();
    expect({
      session: await state("resume-inactive-state"),
      plan: await readFile(plan.path, "utf8"),
      project: await readFile(join(cwd, "project.ts"), "utf8"),
      notice: written(
        restored.findLast((entry) => entry.type === "custom_message"),
      ),
      saved: written(
        restored.findLast(
          (entry) => entry.type === "custom" && entry.customType === stateEntry,
        ),
      ),
    }).toStrictEqual({
      session: source,
      plan: expectedPlan,
      project: "unapproved",
      notice: {
        custom: "dotfiles:planning-exit:v1",
        content: planExitReminder(plan.path),
        display: false,
      },
      saved: {
        custom: stateEntry,
        data: {
          version: 1,
          active: false,
          sourceSessionId: source.sessionId,
          exitReminderPending: false,
        },
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
});

it.each([
  { decision: "declined", response: { confirmed: false } },
  { decision: "cancelled", response: { cancelled: true } },
  { decision: "malformed", response: { confirmed: "yes" } },
])(
  "keeps native Plan mode inactive when entry is $decision",
  async ({ response }) => {
    const cwd = await mkdtemp(join(tmpdir(), "pi-entry-consent-"));
    await mkdir(join(cwd, "agent"));
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
      fileURLToPath(new URL("../index.ts", import.meta.url)),
      "-e",
      fileURLToPath(new URL("./fixtures/provider.ts", import.meta.url)),
    ];
    const nativeHost = process.env.PI_TEST_HOST;
    const useNativeHost = nativeHost !== undefined && nativeHost !== "";
    const child = spawn(
      useNativeHost ? nativeHost : process.execPath,
      useNativeHost ? args : [join(sdk, "bundle/cli.js"), ...args],
      {
        cwd,
        env: {
          ...process.env,
          HOME: cwd,
          PI_CODING_AGENT_DIR: join(cwd, "agent"),
          PI_OFFLINE: "1",
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    const records: RecordLine[] = [];
    const waits = new RecordWaits();
    const output = createInterface({ input: child.stdout });
    output.on("line", (line) => {
      records.push(recordLine(JSON.parse(line)));
      waits.notify();
    });
    let errors = "";
    child.stderr.on("data", (data: Buffer) => {
      errors += data.toString();
    });
    const send = (value: unknown) =>
      child.stdin.write(JSON.stringify(value) + "\n");
    try {
      send({ type: "prompt", message: "Exercise entry consent." });
      const consent = (item: RecordLine) =>
        item.type === "extension_ui_request" && item.method === "confirm";
      await waits.until(
        child,
        () => records.some((item) => consent(item)),
        () => `Expected entry consent: ${errors}`,
      );
      const question = records.find((item) => consent(item));
      if (question === undefined) {
        throw new Error("Expected the entry consent record.");
      }
      const source = await sessionState(
        send,
        (condition) =>
          waits.until(
            child,
            condition,
            () => `Expected the session state: ${errors}`,
          ),
        records,
        "state",
      );
      const plan = new PlanStore(
        join(cwd, "agent/plans"),
        source.sessionId,
        nodeFiles,
      );
      expect({
        title: question.title,
        planExists: plan.exists(),
        saved: SessionManager.open(source.sessionFile)
          .getBranch()
          .filter(
            (item) => item.type === "custom" && item.customType === stateEntry,
          ),
      }).toStrictEqual({
        title: "Enter Plan mode?",
        planExists: false,
        saved: [],
      });

      send({ type: "extension_ui_response", id: question.id, ...response });
      await waits.until(
        child,
        () => records.some((item) => item.type === "agent_settled"),
        () => `The entry consent fixture has not settled: ${errors}`,
      );
      const manager = SessionManager.open(source.sessionFile);
      const result = manager
        .buildSessionContext()
        .messages.find(
          (message) =>
            message.role === "toolResult" && message.toolCallId === "enter",
        );
      expect({
        result:
          result?.role === "toolResult"
            ? {
                content: result.content,
                isError: result.isError,
              }
            : undefined,
        planExists: plan.exists(),
        saved: manager
          .getBranch()
          .filter(
            (item) => item.type === "custom" && item.customType === stateEntry,
          ),
      }).toStrictEqual({
        result: {
          content: [
            {
              type: "text",
              text: "Plan mode was not entered. Continue in the current mode and follow the user's request.",
            },
          ],
          isError: false,
        },
        planExists: false,
        saved: [],
      });
    } finally {
      output.close();
      if (child.exitCode === null) {
        const exited = once(child, "exit");
        child.kill();
        await exited;
      }
      await rm(cwd, { recursive: true, force: true });
    }
  },
);
