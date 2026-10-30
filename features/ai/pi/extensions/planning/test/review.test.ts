import { stripVTControlCharacters } from "node:util";
import { initTheme } from "@earendil-works/pi-coding-agent";
import { matchesKey, visibleWidth, type KeyId } from "@earendil-works/pi-tui";
import { afterEach, beforeAll, expect, it, vi } from "vitest";
import {
  reviewPlan,
  type ReviewContext,
  type ReviewDecision,
  type ReviewRequest,
  type ReviewResult,
  type ReviewTerminal,
} from "../src/review.ts";
import type { PlanRevision } from "../src/store.ts";

beforeAll(() => initTheme("dark", false));
const aborts: AbortController[] = [];
afterEach(() => {
  for (const abort of aborts.splice(0)) {
    abort.abort();
  }
});
const original: PlanRevision = {
  path: "/plans/document.md",
  revision: "original-revision",
  content: "Private plan body",
};
const edited: PlanRevision = {
  ...original,
  revision: "edited-revision",
  content: "Edited plan body",
};
type ReviewComponent = ReturnType<Parameters<ReviewContext["ui"]["custom"]>[0]>;

function fixture(editorKey: KeyId = "ctrl+g") {
  const abort = new AbortController();
  aborts.push(abort);
  const present = vi.fn<ReviewRequest["present"]>();
  const read = vi.fn<ReviewRequest["read"]>(() => original);
  const edit = vi.fn<(path: string) => Promise<void>>(async () => {});
  const done = vi.fn<(result: ReviewResult) => void>();
  const tui = {
    terminal: { rows: 24 },
    requestRender: vi.fn<ReviewTerminal["requestRender"]>(),
    stop: vi.fn<ReviewTerminal["stop"]>(),
    start: vi.fn<ReviewTerminal["start"]>(),
  };
  let component: ReviewComponent | undefined;
  const ctx: ReviewContext = {
    mode: "tui",
    hasUI: true,
    ui: {
      select: vi.fn<ReviewContext["ui"]["select"]>(),
      custom: (factory) =>
        new Promise((resolve) => {
          component = factory(
            tui,
            { fg: (_color, text) => text },
            {
              matches: (input, action) =>
                action === "app.editor.external" &&
                matchesKey(input, editorKey),
              getKeys: () => [editorKey],
            },
            (result) => {
              done(result);
              component?.dispose();
              resolve(result);
            },
          );
        }),
    },
  };
  const pending = reviewPlan(
    ctx,
    { plan: original, signal: abort.signal, present, read },
    edit,
  );
  const question = () => {
    if (!component) {
      throw new Error("Expected an open plan question.");
    }
    return component;
  };
  const lines = (width = 90) =>
    question()
      .render(width)
      .map((line) => stripVTControlCharacters(line));
  return { abort, present, read, edit, done, tui, pending, question, lines };
}

it.each([
  { key: "a", decision: "current" },
  { key: "c", decision: "clear" },
  { key: "r", decision: "revise" },
  { key: "\u001B", decision: "cancel" },
] satisfies { key: string; decision: ReviewDecision }[])(
  "reviews the plan with $key",
  async ({ key, decision }) => {
    const f = fixture();
    f.question().handleInput?.(key);
    f.abort.abort();
    const expected = { decision, presentedPlan: original };
    expect({
      result: await f.pending,
      decisions: f.done.mock.calls,
      presented: f.present.mock.calls,
    }).toStrictEqual({
      result: expected,
      decisions: [[expected]],
      presented: [[original]],
    });
  },
);

it("advertises every approval accelerator beside its native choice", () => {
  const f = fixture();
  const choices = f.lines().flatMap((line) => {
    const start = line.indexOf("[");
    return start === -1 ? [] : [line.slice(start).trimEnd()];
  });
  expect(choices).toStrictEqual([
    "[a] Approve and keep context",
    "[c] Approve and clear context",
    "[r] Revise the plan",
    "[Esc] Continue planning",
  ]);
});

it("keeps the plan in the transcript rather than a private question viewport", async () => {
  const f = fixture();
  const before = f.lines();
  f.question().handleInput?.("\u001B[6~");
  expect({
    containsPlan: before.some((line) => line.includes(original.content)),
    question: before.some((line) => line.includes("Approve this plan?")),
    stableDock: f.lines(),
  }).toStrictEqual({ containsPlan: false, question: true, stableDock: before });
  f.abort.abort();
  await f.pending;
});

it.each([12, 40, 90])("keeps the question within %i columns", (width) => {
  const f = fixture();
  expect(
    f.lines(width).filter((line) => visibleWidth(line) > width),
  ).toStrictEqual([]);
});

it("uses native choice navigation and retains it across resizing", async () => {
  const f = fixture();
  f.question().handleInput?.("\u001B[B");
  f.tui.terminal.rows = 10;
  f.lines(40);
  f.tui.terminal.rows = 24;
  f.lines();
  f.question().handleInput?.("\r");
  expect(await f.pending).toStrictEqual({
    decision: "clear",
    presentedPlan: original,
  });
});

it.each([
  { key: "ctrl+g", input: "\u0007" },
  { key: "ctrl+e", input: "\u0005" },
] satisfies { key: KeyId; input: string }[])(
  "opens the actual plan using the configured $key binding",
  async ({ key, input }) => {
    const f = fixture(key);
    const editor = Promise.withResolvers<void>();
    f.edit.mockReturnValueOnce(editor.promise);
    f.read.mockReturnValueOnce(edited);
    f.question().handleInput?.(input);
    f.question().handleInput?.(input);
    f.question().handleInput?.("a");
    expect({
      edits: f.edit.mock.calls,
      decisions: f.done.mock.calls,
    }).toStrictEqual({ edits: [[original.path]], decisions: [] });
    editor.resolve();
    await expect
      .poll(() => f.present.mock.calls)
      .toStrictEqual([[original], [edited]]);
    expect({
      stopped: f.tui.stop.mock.calls,
      started: f.tui.start.mock.calls,
      decisions: f.done.mock.calls,
      revisionVisible: f.lines().some((line) => line.includes(edited.revision)),
    }).toStrictEqual({
      stopped: [[]],
      started: [[]],
      decisions: [],
      revisionVisible: true,
    });
    f.question().handleInput?.("a");
    expect(await f.pending).toStrictEqual({
      decision: "current",
      presentedPlan: edited,
    });
  },
);

it("restores the terminal and rereads saved edits after editor failure", async () => {
  const f = fixture();
  f.edit.mockRejectedValueOnce(new Error("Editor failed"));
  f.read.mockReturnValueOnce(edited);
  f.question().handleInput?.("\u0007");
  await expect
    .poll(() => f.present.mock.calls)
    .toStrictEqual([[original], [edited]]);
  expect({
    started: f.tui.start.mock.calls,
    warning: f.lines().some((line) => line.includes("Editor failed")),
    decisions: f.done.mock.calls,
  }).toStrictEqual({ started: [[]], warning: true, decisions: [] });
  f.question().handleInput?.("r");
  expect(await f.pending).toStrictEqual({
    decision: "revise",
    presentedPlan: edited,
  });
});

it.each(["missing", "empty", "template"])(
  "refuses approval of a %s plan after editing",
  async (state) => {
    const f = fixture();
    if (state === "missing") {
      f.read.mockImplementationOnce(() => {
        throw new Error("Plan is missing");
      });
    }
    if (state === "empty") {
      f.read.mockReturnValueOnce({ ...edited, content: "" });
    }
    if (state === "template") {
      f.read.mockReturnValueOnce({
        ...edited,
        content:
          "# Implementation plan\n\nDraft the recommended approach here.\n",
      });
    }
    f.question().handleInput?.("\u0007");
    await expect.poll(() => f.read.mock.calls).toStrictEqual([[]]);
    f.question().handleInput?.("a");
    f.question().handleInput?.("c");
    expect(f.done.mock.calls).toStrictEqual([]);
    f.question().handleInput?.("\u001B");
    expect((await f.pending).decision).toBe("cancel");
  },
);

it("does not revive an aborted question after the editor returns", async () => {
  const f = fixture();
  const editor = Promise.withResolvers<void>();
  f.edit.mockReturnValueOnce(editor.promise);
  f.question().handleInput?.("\u0007");
  f.abort.abort();
  const expected = { decision: "cancel", presentedPlan: original };
  expect(await f.pending).toStrictEqual(expected);
  editor.resolve();
  await expect.poll(() => f.tui.start.mock.calls).toStrictEqual([[]]);
  expect({
    presented: f.present.mock.calls,
    decisions: f.done.mock.calls,
  }).toStrictEqual({ presented: [[original]], decisions: [[expected]] });
});
