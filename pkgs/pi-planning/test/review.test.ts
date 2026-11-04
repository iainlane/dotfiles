import { stripVTControlCharacters } from "node:util";
import { initTheme } from "@earendil-works/pi-coding-agent";
import {
  getKeybindings,
  KeybindingsManager,
  matchesKey,
  setKeybindings,
  TUI_KEYBINDINGS,
  TuiAltScreen,
  visibleWidth,
  type KeyId,
  type TuiMouseEvent,
} from "@earendil-works/pi-tui";
import { afterAll, afterEach, beforeAll, expect, it, vi } from "vitest";
import {
  reviewPlan,
  type ReviewContext,
  type ReviewDecision,
  type ReviewRequest,
  type ReviewResult,
  type ReviewTerminal,
} from "../src/review.ts";
import type { PlanRevision } from "../src/store.ts";
import { TestTerminal } from "./terminal.ts";
import { feedbackImage } from "./fixtures/image.ts";

const previousKeys = getKeybindings();
beforeAll(() => {
  initTheme("dark", false);
  setKeybindings(
    new KeybindingsManager({
      ...TUI_KEYBINDINGS,
      "app.tools.expand": { defaultKeys: "ctrl+o" },
    }),
  );
});
afterAll(() => setKeybindings(previousKeys));
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
  // Checks the conditions that tests wait for, after each call that can change
  // the review's state.
  const waiters = new Set<() => void>();
  const notify = () => {
    for (const check of waiters) {
      check();
    }
  };
  const present = vi.fn<ReviewRequest["present"]>(notify);
  const read = vi.fn<ReviewRequest["read"]>(() => original);
  const readImage = vi.fn<NonNullable<ReviewRequest["readImage"]>>(
    async () => feedbackImage,
  );
  const getContextUsage =
    vi.fn<NonNullable<ReviewContext["getContextUsage"]>>();
  const edit = vi.fn<(path: string) => Promise<void>>(async () => {});
  const done = vi.fn<(result: ReviewResult) => void>();
  const expanded = vi.fn<ReviewContext["ui"]["getToolsExpanded"]>(() => false);
  const setExpanded = vi.fn<ReviewContext["ui"]["setToolsExpanded"]>();
  const terminal = new TestTerminal();
  const tui = Object.assign(new TuiAltScreen(terminal), {
    requestRender: vi.fn<ReviewTerminal["requestRender"]>(notify),
    stop: vi.fn<ReviewTerminal["stop"]>(notify),
    start: vi.fn<ReviewTerminal["start"]>(notify),
  });
  let component: ReviewComponent | undefined;
  const customOptions: Parameters<ReviewContext["ui"]["custom"]>[1][] = [];
  const ctx: ReviewContext = {
    mode: "tui",
    hasUI: true,
    model: { input: ["text", "image"] },
    getContextUsage,
    ui: {
      select: vi.fn<ReviewContext["ui"]["select"]>(),
      input: vi.fn<ReviewContext["ui"]["input"]>(),
      getToolsExpanded: expanded,
      setToolsExpanded: setExpanded,
      custom: (factory, options) => {
        customOptions.push(options);
        return new Promise((resolve) => {
          component = factory(
            tui,
            { fg: (_color, text) => text },
            {
              matches: (input, action) =>
                (action === "app.editor.external" &&
                  matchesKey(input, editorKey)) ||
                (action === "app.clipboard.pasteImage" &&
                  matchesKey(input, "ctrl+v")),
              getKeys: (action) =>
                action === "app.clipboard.pasteImage"
                  ? ["ctrl+v"]
                  : [editorKey],
            },
            (result) => {
              done(result);
              component?.dispose();
              resolve(result);
            },
          );
        });
      },
    },
  };
  const pending = reviewPlan(
    ctx,
    {
      plan: original,
      signal: abort.signal,
      present,
      read: () => {
        try {
          return read();
        } finally {
          notify();
        }
      },
      readImage,
    },
    { name: "nvim", open: edit },
  );
  let finished = false;
  const markFinished = () => {
    finished = true;
  };
  pending.then(markFinished, markFinished);
  // Resolves once `predicate` is true. If the review finishes while the wait is
  // pending, the wait rejects. A wait that starts after the review has
  // finished does not reject, because the editor can still restart the TUI.
  const until = (predicate: () => boolean) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (predicate()) {
          waiters.delete(check);
          resolve();
        }
      };
      waiters.add(check);
      check();
      if (!finished) {
        const rejectIfWaiting = () => {
          if (waiters.delete(check)) {
            reject(new Error("The review finished before the awaited state."));
          }
        };
        pending.then(rejectIfWaiting, rejectIfWaiting);
      }
    });
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
  return {
    abort,
    ctx,
    present,
    read,
    readImage,
    getContextUsage,
    edit,
    done,
    setExpanded,
    tui,
    terminal,
    pending,
    question,
    lines,
    until,
    customOptions,
  };
}

it.each([
  { keys: ["\r"], decision: "current" },
  { keys: ["\u001B[B", "\r"], decision: "clear" },
  {
    keys: ["\t", "Revise this", "\r"],
    decision: "revise",
    feedback: "Revise this",
  },
  { keys: ["\u001B"], decision: "cancel" },
] satisfies { keys: string[]; decision: ReviewDecision; feedback?: string }[])(
  "reviews the plan with native keys $keys",
  async ({ keys, decision, feedback }) => {
    const f = fixture();
    for (const key of keys) {
      f.question().handleInput?.(key);
    }
    f.abort.abort();
    const expected = {
      decision,
      presentedPlan: original,
      ...(feedback === undefined ? {} : { feedback }),
    };
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

it.each(["current", "clear", "revise"] as const)(
  "retains native clipboard images with a %s decision",
  async (decision) => {
    const f = fixture();
    f.question().handleInput?.("\u0016");
    await f.until(() =>
      f.lines().some((line) => line.includes("Attached image")),
    );
    if (decision !== "revise") {
      f.question().handleInput?.("\u001B");
      f.question().handleInput?.("\u001B[A");
    }
    if (decision === "current") {
      f.question().handleInput?.("\u001B[A");
    }
    f.question().handleInput?.("\r");
    expect(await f.pending).toStrictEqual({
      decision,
      presentedPlan: original,
      images: [feedbackImage],
    });
  },
);

it("keeps text feedback available when the model cannot receive images", async () => {
  const f = fixture();
  f.ctx.model = { input: ["text"] };
  f.question().handleInput?.("\u0016");
  await f.until(() =>
    f.lines().some((line) => line.includes("image-capable model")),
  );
  for (const input of ["\t", "Text feedback", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect({
    reads: f.readImage.mock.calls,
    result: await f.pending,
  }).toStrictEqual({
    reads: [],
    result: {
      decision: "revise",
      presentedPlan: original,
      feedback: "Text feedback",
    },
  });
});

it("drops late clipboard images after review cancellation", async () => {
  const f = fixture();
  const image = Promise.withResolvers<typeof feedbackImage>();
  f.readImage.mockReturnValueOnce(image.promise);
  f.question().handleInput?.("\u0016");
  f.abort.abort();
  const expected = { decision: "cancel", presentedPlan: original };
  expect(await f.pending).toStrictEqual(expected);
  image.resolve(feedbackImage);
  await image.promise;
  expect({
    reads: f.readImage.mock.calls,
    decisions: f.done.mock.calls,
    attached: f.lines().some((line) => line.includes("Attached image")),
  }).toStrictEqual({ reads: [[]], decisions: [[expected]], attached: false });
});

it("waits for pending clipboard acquisition before accepting approval", async () => {
  const f = fixture();
  const image = Promise.withResolvers<typeof feedbackImage>();
  f.readImage.mockReturnValueOnce(image.promise);
  f.question().handleInput?.("\u0016");
  f.question().handleInput?.("\r");
  expect({
    decisions: f.done.mock.calls,
    waiting: f.lines().some((line) => line.includes("Wait for the clipboard")),
  }).toStrictEqual({ decisions: [], waiting: true });
  image.resolve(feedbackImage);
  await image.promise;
  for (const input of ["\u001B", "\u001B[A", "\u001B[A", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "current",
    presentedPlan: original,
    images: [feedbackImage],
  });
});

it("keeps text feedback available after a clipboard transfer failure", async () => {
  const f = fixture();
  f.readImage.mockRejectedValueOnce(new Error("Clipboard transfer failed"));
  f.question().handleInput?.("\u0016");
  await f.until(() =>
    f.lines().some((line) => line.includes("Clipboard transfer failed")),
  );
  for (const input of ["\t", "Text feedback", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "revise",
    presentedPlan: original,
    feedback: "Text feedback",
  });
});

it("retains native images and text through external-editor failure and saved readback", async () => {
  const f = fixture();
  f.question().handleInput?.("\u0016");
  await f.until(() =>
    f.lines().some((line) => line.includes("Attached image")),
  );
  f.question().handleInput?.("Keep this interface.");
  f.read.mockReturnValueOnce(edited);
  f.edit.mockRejectedValueOnce(new Error("Editor failed"));
  f.question().handleInput?.("\u0007");
  await f.until(() => f.present.mock.calls.length === 2);
  expect(f.present.mock.calls).toStrictEqual([[original], [edited]]);
  for (const input of ["\u001B", "\u001B[A", "\u001B[A", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "current",
    presentedPlan: edited,
    feedback: "Keep this interface.",
    images: [feedbackImage],
  });
});

it("discards attached images and unsent text when cancelling from the choices", async () => {
  const f = fixture();
  f.question().handleInput?.("\u0016");
  await f.until(() =>
    f.lines().some((line) => line.includes("Attached image")),
  );
  for (const input of ["Unsent", "\u001B", "\u001B"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "cancel",
    presentedPlan: original,
  });
});

it.each([undefined, "", " \n "])(
  "does not submit empty revision feedback over RPC: %j",
  async (feedback) => {
    const abort = new AbortController();
    const result = await reviewPlan(
      {
        hasUI: true,
        mode: "rpc",
        ui: {
          select: async () => "No, keep planning",
          input: async () => feedback,
          getToolsExpanded: () => false,
          setToolsExpanded: () => {},
          custom: async () => {
            throw new Error("RPC must not open a custom TUI");
          },
        },
      },
      {
        plan: original,
        signal: abort.signal,
        read: () => original,
        present: () => {},
      },
      { name: "nvim", open: async () => {} },
    );
    expect(result).toStrictEqual({
      decision: "cancel",
      presentedPlan: original,
    });
  },
);

it.each([
  { choice: undefined, invalid: "oversized" },
  { choice: "Continue planning", invalid: "oversized" },
  { choice: undefined, invalid: "unicode" },
  { choice: "Continue planning", invalid: "unicode" },
])(
  "discards $invalid RPC feedback when cancelling with $choice",
  async ({ choice, invalid }) => {
    const select = vi
      .fn<ReviewContext["ui"]["select"]>()
      .mockResolvedValueOnce("Add a comment")
      .mockResolvedValueOnce(choice);
    const result = await reviewPlan(
      {
        mode: "rpc",
        hasUI: true,
        ui: {
          select,
          input: async () =>
            invalid === "oversized" ? "a".repeat(200001) : "\uD800",
          getToolsExpanded: () => false,
          setToolsExpanded: () => {},
          custom: async () => {
            throw new Error("RPC must not open a custom TUI");
          },
        },
      },
      {
        plan: original,
        signal: new AbortController().signal,
        read: () => original,
        present: () => {},
      },
      { name: "unused", open: async () => {} },
    );
    expect(result).toStrictEqual({
      decision: "cancel",
      presentedPlan: original,
    });
  },
);

it.each([null, 0, 42])(
  "uses Pi's native context usage without estimating unknown values: %s",
  (percent) => {
    const f = fixture();
    f.getContextUsage.mockReturnValue({
      tokens: percent === null ? null : percent * 10,
      contextWindow: 1000,
      percent,
    });
    expect(
      f
        .lines()
        .filter((line) => line.includes("Context:"))
        .map((line) => line.trim()),
    ).toStrictEqual(percent === null ? [] : [`Context: ${percent}%`]);
  },
);

it("embeds multiline feedback between the other action rows", () => {
  const f = fixture();
  for (const input of [
    "\u001B[B",
    "\u001B[B",
    "\r",
    "First line",
    "\u001B\r",
    "Second line",
  ]) {
    f.question().handleInput?.(input);
  }
  const output = f.lines().join("\n");
  expect({
    keep: output.includes("Yes, keep context"),
    clear: output.includes("Yes, clear context"),
    firstLine: output.includes("First line"),
    secondLine: output.includes("Second line"),
    before: output.indexOf("Yes, clear context") < output.indexOf("First line"),
    after: output.indexOf("Continue planning") > output.indexOf("Second line"),
    decisions: f.done.mock.calls,
  }).toStrictEqual({
    keep: true,
    clear: true,
    firstLine: true,
    secondLine: true,
    before: true,
    after: true,
    decisions: [],
  });
});

it("keeps oversized feedback editable without accepting a decision", async () => {
  const f = fixture();
  for (const input of ["\t", "x".repeat(200_001), "\r"]) {
    f.question().handleInput?.(input);
  }
  expect({
    decisions: f.done.mock.calls,
    guidance: f.lines().some((line) => line.includes("200,000 UTF-16")),
  }).toStrictEqual({ decisions: [], guidance: true });
  f.abort.abort();
  expect(await f.pending).toStrictEqual({
    decision: "cancel",
    presentedPlan: original,
  });
});

it("requires nonempty feedback before submitting revisions", async () => {
  const f = fixture();
  for (const input of ["\t", "\r", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect({
    decisions: f.done.mock.calls,
    guidance: f.lines().some((line) => line.includes("Write feedback")),
  }).toStrictEqual({ decisions: [], guidance: true });
  f.question().handleInput?.("Change the approach.");
  f.question().handleInput?.("\r");
  expect(await f.pending).toStrictEqual({
    decision: "revise",
    presentedPlan: original,
    feedback: "Change the approach.",
  });
});

it("keeps letters, numbers and multiline Unicode text in the embedded editor", async () => {
  const f = fixture();
  for (const input of [
    "\t",
    "jka1cr",
    "\u001B\r",
    "日本語 🦉",
    "\u001B",
    "\u001B[A",
    "\r",
  ]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "clear",
    presentedPlan: original,
    feedback: "jka1cr\n日本語 🦉",
  });
});

it.each([
  { type: "wheel", button: "none", wheelDelta: -1 },
  { type: "wheel", button: "none", wheelDelta: 1 },
  { type: "move", button: "none" },
  { type: "press", button: "right" },
  { type: "click", button: "right" },
  { type: "release", button: "left" },
  { type: "drag", button: "left" },
] satisfies Pick<TuiMouseEvent, "type" | "button" | "wheelDelta">[])(
  "preserves feedback editing on an action-row $type event with $button",
  async (event) => {
    const f = fixture();
    f.question().focused = true;
    f.question().handleInput?.("\t");
    f.question().handleInput?.("Please revise");
    const lines = f.lines(90);
    const y = lines.findIndex((line) => line.includes("Yes, keep context"));
    f.question().handleMouse?.({
      ...event,
      x: 2,
      y,
      screenX: 2,
      screenY: y,
      width: 90,
      height: lines.length,
      shift: false,
      alt: false,
      ctrl: false,
    });
    f.question().handleInput?.(" the plan.");
    f.question().handleInput?.("\r");
    expect(await f.pending).toStrictEqual({
      decision: "revise",
      presentedPlan: original,
      feedback: "Please revise the plan.",
    });
  },
);

it("uses the embedded editor's native mouse cursor placement", async () => {
  const f = fixture();
  f.question().focused = true;
  f.question().handleInput?.("\t");
  f.question().handleInput?.("hello world");
  const lines = f.lines(50);
  const y = lines.findIndex((line) => line.includes("hello world"));
  expect(y).toBeGreaterThan(0);
  f.question().handleMouse?.({
    type: "click",
    button: "left",
    x: 0,
    y,
    screenX: 0,
    screenY: y,
    width: 50,
    height: lines.length,
    shift: false,
    alt: false,
    ctrl: false,
  });
  for (const input of ["X", "\u001B", "\u001B[A", "\u001B[A", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "current",
    presentedPlan: original,
    feedback: "Xhello world",
  });
});

it.each([
  { width: 18, height: 12 },
  { width: 30, height: 10 },
])(
  "keeps actions visible with multiline feedback at $width columns and $height rows",
  ({ width, height }) => {
    const f = fixture();
    f.question().focused = true;
    f.terminal.rows = height;
    f.question().handleInput?.("\t");
    for (let index = 0; index < 8; index++) {
      f.question().handleInput?.(`Line ${index}`);
      f.question().handleInput?.("\u001B\r");
    }
    f.question().handleInput?.("Last line");
    const lines = f.lines(width);
    expect({
      fits: lines.length <= height,
      keep: lines.some((line) => line.includes("Yes, keep")),
      clear: lines.some((line) => line.includes("Yes, clear")),
      negative: lines.some((line) => line.includes("No,")),
      cancel: lines.some((line) => line.includes("Continue")),
      cursorLine: lines.some((line) => line.includes("Last line")),
      overwide: lines.filter((line) => visibleWidth(line) > width),
    }).toStrictEqual({
      fits: true,
      keep: true,
      clear: true,
      negative: true,
      cancel: true,
      cursorLine: true,
      overwide: [],
    });
  },
);

it("shows the native choices and configured editor hint without a separate comment page", () => {
  const f = fixture();
  const output = f.lines().join("\n");
  expect({
    title: output.includes("Ready to code?"),
    choices: f
      .lines()
      .filter((line) => /Yes,|No,|Continue planning/.test(line))
      .map((line) => line.replace("→", "").trim()),
    editor: output.includes("ctrl+g edit in nvim"),
    commentPage: output.includes("Add a comment"),
    planBody: output.includes(original.content),
  }).toStrictEqual({
    title: true,
    choices: [
      "Yes, keep context",
      "Yes, clear context",
      "No, keep planning",
      "Continue planning",
    ],
    editor: true,
    commentPage: false,
    planBody: false,
  });
});

it.each(["current", "clear"] as const)(
  "includes an optional comment with a %s approval",
  async (decision) => {
    const f = fixture();
    for (const input of ["\t", "Keep the public API.", "\u001B", "\u001B[A"]) {
      f.question().handleInput?.(input);
    }
    expect(f.done.mock.calls).toStrictEqual([]);
    if (decision === "current") {
      f.question().handleInput?.("\u001B[A");
    }
    f.question().handleInput?.("\r");
    expect(await f.pending).toStrictEqual({
      decision,
      presentedPlan: original,
      feedback: "Keep the public API.",
    });
  },
);

it("treats a custom response as revision feedback, not approval", async () => {
  const f = fixture();
  for (const input of [
    "\t",
    "Use the existing API.",
    "\u001B\r",
    "Keep its types.",
    "\r",
  ]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "revise",
    presentedPlan: original,
    feedback: "Use the existing API.\nKeep its types.",
  });
});

it("does not approve or submit a comment when its editor is cancelled", async () => {
  const f = fixture();
  for (const input of ["\t", "Unsubmitted comment", "\u001B"]) {
    f.question().handleInput?.(input);
  }
  expect(f.done.mock.calls).toStrictEqual([]);
  f.question().handleInput?.("\u001B");
  expect(await f.pending).toStrictEqual({
    decision: "cancel",
    presentedPlan: original,
  });
});

it("preserves the comment while the actual plan is edited", async () => {
  const f = fixture();
  for (const input of ["\t", "Keep the public API."]) {
    f.question().handleInput?.(input);
  }
  f.read.mockReturnValueOnce(edited);
  f.question().handleInput?.("\u0007");
  await f.until(() => f.present.mock.calls.length === 2);
  expect(f.present.mock.calls).toStrictEqual([[original], [edited]]);
  for (const input of ["\u001B", "\u001B[A", "\u001B[A", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "current",
    presentedPlan: edited,
    feedback: "Keep the public API.",
  });
});

it("bounds the embedded editor without truncating submitted feedback", async () => {
  const f = fixture();
  const feedback = "Keep the existing public interface. ".repeat(50).trimEnd();
  for (const input of ["\t", feedback, "\u001B", "\u001B[A", "\u001B[A"]) {
    f.question().handleInput?.(input);
  }
  const lines = f.lines(40);
  f.question().handleInput?.("\r");
  expect({
    fits: lines.length <= f.terminal.rows,
    overwide: lines.filter((line) => visibleWidth(line) > 40),
    result: await f.pending,
  }).toStrictEqual({
    fits: true,
    overwide: [],
    result: { decision: "current", presentedPlan: original, feedback },
  });
});

it("does not add letter accelerators to the choice list", () => {
  const f = fixture();
  for (const key of ["a", "c", "r"]) {
    f.question().handleInput?.(key);
  }
  expect(f.done.mock.calls).toStrictEqual([]);
});

it("reports pi as waiting for the plan decision", async () => {
  const f = fixture();
  expect(f.customOptions).toStrictEqual([
    { blocked: { kind: "question", message: "Plan ready for review" } },
  ]);
  f.abort.abort();
  await f.pending;
});

it("retains the native tool-expansion shortcut", () => {
  const f = fixture();
  f.question().handleInput?.("\u000F");
  expect({
    expanded: f.setExpanded.mock.calls,
    decisions: f.done.mock.calls,
  }).toStrictEqual({ expanded: [[true]], decisions: [] });
});

it("keeps the plan in the transcript rather than a private question viewport", async () => {
  const f = fixture();
  const before = f.lines();
  f.question().handleInput?.("\u001B[6~");
  const after = f.lines();
  expect({
    containsPlan: [before, after].map((lines) =>
      lines.some((line) => line.includes(original.content)),
    ),
    question: after.some((line) => line.includes("Ready to code?")),
    height: after.length,
  }).toStrictEqual({
    containsPlan: [false, false],
    question: true,
    height: before.length,
  });
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
  f.terminal.rows = 10;
  f.lines(40);
  f.terminal.rows = 24;
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
    f.question().handleInput?.("\r");
    expect({
      edits: f.edit.mock.calls,
      decisions: f.done.mock.calls,
    }).toStrictEqual({ edits: [[original.path]], decisions: [] });
    editor.resolve();
    await f.until(() => f.present.mock.calls.length === 2);
    expect(f.present.mock.calls).toStrictEqual([[original], [edited]]);
    expect({
      stopped: f.tui.stop.mock.calls,
      started: f.tui.start.mock.calls,
      decisions: f.done.mock.calls,
      editorHint: f
        .lines()
        .some((line) => line.includes(`${key} edit in nvim · ${edited.path}`)),
    }).toStrictEqual({
      stopped: [[]],
      started: [[]],
      decisions: [],
      editorHint: true,
    });
    f.question().handleInput?.("\r");
    expect(await f.pending).toStrictEqual({
      decision: "current",
      presentedPlan: edited,
    });
  },
);

it("keeps the presented revision when the editor leaves the contents unchanged", async () => {
  const f = fixture();
  f.read.mockReturnValue({ ...original });
  f.question().handleInput?.("\u0007");
  await f.until(() => f.read.mock.calls.length === 1);
  expect(f.read.mock.calls).toStrictEqual([[]]);
  f.question().handleInput?.("\r");
  expect({
    presented: f.present.mock.calls,
    result: await f.pending,
  }).toStrictEqual({
    presented: [[original]],
    result: { decision: "current", presentedPlan: original },
  });
});

it("restores the terminal and rereads saved edits after editor failure", async () => {
  const f = fixture();
  f.edit.mockRejectedValueOnce(new Error("Editor failed"));
  f.read.mockReturnValueOnce(edited);
  f.question().handleInput?.("\u0007");
  await f.until(() => f.present.mock.calls.length === 2);
  expect(f.present.mock.calls).toStrictEqual([[original], [edited]]);
  expect({
    started: f.tui.start.mock.calls,
    warning: f.lines().some((line) => line.includes("Editor failed")),
    decisions: f.done.mock.calls,
  }).toStrictEqual({ started: [[]], warning: true, decisions: [] });
  for (const input of ["\t", "Revise the saved plan.", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "revise",
    presentedPlan: edited,
    feedback: "Revise the saved plan.",
  });
});

it.each(["missing", "empty", "template", "oversized"])(
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
    if (state === "oversized") {
      f.read.mockReturnValueOnce({ ...edited, content: "x".repeat(200_001) });
    }
    if (state === "template") {
      f.read.mockReturnValueOnce({
        ...edited,
        content:
          "# Implementation plan\n\nDraft the recommended approach here.\n",
      });
    }
    f.question().handleInput?.("\u0007");
    await f.until(() => f.read.mock.calls.length === 1);
    expect(f.read.mock.calls).toStrictEqual([[]]);
    f.question().handleInput?.("\r");
    f.question().handleInput?.("\u001B[B");
    f.question().handleInput?.("\r");
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
  await f.until(() => f.tui.start.mock.calls.length === 1);
  expect(f.tui.start.mock.calls).toStrictEqual([[]]);
  expect({
    presented: f.present.mock.calls,
    decisions: f.done.mock.calls,
  }).toStrictEqual({ presented: [[original]], decisions: [[expected]] });
});
