import { stripVTControlCharacters } from "node:util";
import type { ImageContent } from "@earendil-works/pi-ai";
import { initTheme, type ContextUsage } from "@earendil-works/pi-coding-agent";
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
import { afterAll, afterEach, beforeAll, expect, it } from "vitest";
import {
  reviewPlan,
  type ReviewContext,
  type ReviewDecision,
  type ReviewResult,
} from "#planning/review.ts";
import type { PlanRevision } from "#planning/store.ts";
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
  const plan = { document: original as PlanRevision | Error };
  const transcript: PlanRevision[] = [];
  const clipboard = {
    read: async (): Promise<ImageContent> => feedbackImage,
  };
  const ui = {
    contextUsage: undefined as ContextUsage | undefined,
    toolsExpanded: false,
    blocked: undefined as unknown,
    result: undefined as ReviewResult | undefined,
  };
  const editor = {
    name: "nvim",
    openPath: undefined as string | undefined,
    saves: undefined as PlanRevision | Error | undefined,
    failure: undefined as Error | undefined,
    closed: Promise.resolve(),
    async open(path: string) {
      if (editor.openPath !== undefined) {
        throw new Error("The fixture editor is already open.");
      }
      if (path !== original.path) {
        throw new Error(`The fixture editor cannot find ${path}.`);
      }
      editor.openPath = path;
      try {
        await editor.closed;
        if (editor.saves !== undefined) {
          plan.document = editor.saves;
        }
        if (editor.failure) {
          throw editor.failure;
        }
      } finally {
        editor.openPath = undefined;
      }
    },
  };
  const terminal = new TestTerminal();
  const screen = { running: true };
  const tui = Object.assign(new TuiAltScreen(terminal), {
    requestRender: notify,
    stop: () => {
      screen.running = false;
      notify();
    },
    start: () => {
      screen.running = true;
      notify();
    },
  });
  let component: ReviewComponent | undefined;
  const ctx: ReviewContext = {
    mode: "tui",
    hasUI: true,
    model: { input: ["text", "image"] },
    getContextUsage: () => ui.contextUsage,
    ui: {
      select: async () => {
        throw new Error("The terminal review must not open a dialog.");
      },
      input: async () => {
        throw new Error("The terminal review must not open a dialog.");
      },
      getToolsExpanded: () => ui.toolsExpanded,
      setToolsExpanded: (expanded) => {
        ui.toolsExpanded = expanded;
      },
      custom: (factory, options) => {
        ui.blocked = options?.blocked;
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
              if (ui.result !== undefined) {
                throw new Error("The plan question closed twice.");
              }
              ui.result = result;
              ui.blocked = undefined;
              component?.dispose();
              resolve(result);
            },
          );
        });
      },
    },
  };
  let finished = false;
  const finishListeners = new Set<() => void>();
  const pending = (async () => {
    try {
      return await reviewPlan(
        ctx,
        {
          plan: original,
          signal: abort.signal,
          present: (presented) => {
            transcript.push(presented);
            notify();
          },
          read: () => {
            try {
              if (plan.document instanceof Error) {
                throw plan.document;
              }
              return plan.document;
            } finally {
              notify();
            }
          },
          readImage: () => clipboard.read(),
        },
        editor,
      );
    } finally {
      finished = true;
      for (const listener of finishListeners) {
        listener();
      }
    }
  })();
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
        finishListeners.add(() => {
          if (waiters.delete(check)) {
            reject(new Error("The review finished before the awaited state."));
          }
        });
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
    plan,
    transcript,
    clipboard,
    ui,
    editor,
    screen,
    terminal,
    pending,
    question,
    lines,
    until,
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
      transcript: f.transcript,
    }).toStrictEqual({
      result: expected,
      transcript: [original],
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
  expect(await f.pending).toStrictEqual({
    decision: "revise",
    presentedPlan: original,
    feedback: "Text feedback",
  });
});

it("drops late clipboard images after review cancellation", async () => {
  const f = fixture();
  const image = Promise.withResolvers<typeof feedbackImage>();
  f.clipboard.read = () => image.promise;
  f.question().handleInput?.("\u0016");
  f.abort.abort();
  const expected = { decision: "cancel", presentedPlan: original };
  expect(await f.pending).toStrictEqual(expected);
  image.resolve(feedbackImage);
  await image.promise;
  expect({
    result: f.ui.result,
    attached: f.lines().some((line) => line.includes("Attached image")),
  }).toStrictEqual({ result: expected, attached: false });
});

it("waits for pending clipboard acquisition before accepting approval", async () => {
  const f = fixture();
  const image = Promise.withResolvers<typeof feedbackImage>();
  f.clipboard.read = () => image.promise;
  f.question().handleInput?.("\u0016");
  f.question().handleInput?.("\r");
  expect({
    result: f.ui.result,
    waiting: f.lines().some((line) => line.includes("Wait for the clipboard")),
  }).toStrictEqual({ result: undefined, waiting: true });
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
  f.clipboard.read = async () => {
    throw new Error("Clipboard transfer failed");
  };
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
  f.editor.saves = edited;
  f.editor.failure = new Error("Editor failed");
  f.question().handleInput?.("\u0007");
  await f.until(() => f.transcript.length === 2);
  expect(f.transcript).toStrictEqual([original, edited]);
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
    const result = await reviewPlan(
      {
        mode: "rpc",
        hasUI: true,
        ui: {
          select: async (_title, options) =>
            options.includes("Add a comment") ? "Add a comment" : choice,
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
    f.ui.contextUsage = {
      tokens: percent === null ? null : percent * 10,
      contextWindow: 1000,
      percent,
    };
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
    result: f.ui.result,
  }).toStrictEqual({
    keep: true,
    clear: true,
    firstLine: true,
    secondLine: true,
    before: true,
    after: true,
    result: undefined,
  });
});

it("keeps oversized feedback editable without accepting a decision", async () => {
  const f = fixture();
  for (const input of ["\t", "x".repeat(200_001), "\r"]) {
    f.question().handleInput?.(input);
  }
  expect({
    result: f.ui.result,
    guidance: f.lines().some((line) => line.includes("200,000 UTF-16")),
  }).toStrictEqual({ result: undefined, guidance: true });
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
    result: f.ui.result,
    guidance: f.lines().some((line) => line.includes("Write feedback")),
  }).toStrictEqual({ result: undefined, guidance: true });
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
    expect(f.ui.result).toBeUndefined();
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
  expect(f.ui.result).toBeUndefined();
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
  f.editor.saves = edited;
  f.question().handleInput?.("\u0007");
  await f.until(() => f.transcript.length === 2);
  expect(f.transcript).toStrictEqual([original, edited]);
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
  expect(f.ui.result).toBeUndefined();
});

it("reports pi as waiting for the plan decision", async () => {
  const f = fixture();
  const waiting = f.ui.blocked;
  f.abort.abort();
  await f.pending;
  expect({ waiting, afterwards: f.ui.blocked }).toStrictEqual({
    waiting: { kind: "question", message: "Plan ready for review" },
    afterwards: undefined,
  });
});

it("retains the native tool-expansion shortcut", () => {
  const f = fixture();
  f.question().handleInput?.("\u000F");
  expect({
    expanded: f.ui.toolsExpanded,
    result: f.ui.result,
  }).toStrictEqual({ expanded: true, result: undefined });
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
    f.editor.closed = editor.promise;
    f.editor.saves = edited;
    f.question().handleInput?.(input);
    f.question().handleInput?.(input);
    f.question().handleInput?.("\r");
    expect({
      editing: f.editor.openPath,
      terminalRunning: f.screen.running,
      result: f.ui.result,
    }).toStrictEqual({
      editing: original.path,
      terminalRunning: false,
      result: undefined,
    });
    editor.resolve();
    await f.until(() => f.screen.running);
    const lines = f.lines();
    expect({
      transcript: f.transcript,
      editing: f.editor.openPath,
      result: f.ui.result,
      editorHint: lines.some((line) =>
        line.includes(`${key} edit in nvim · ${edited.path}`),
      ),
      editorError: lines.some((line) => line.includes("already open")),
    }).toStrictEqual({
      transcript: [original, edited],
      editing: undefined,
      result: undefined,
      editorHint: true,
      editorError: false,
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
  f.editor.saves = { ...original };
  f.question().handleInput?.("\u0007");
  await f.until(() => f.screen.running);
  f.question().handleInput?.("\r");
  expect({
    transcript: f.transcript,
    result: await f.pending,
  }).toStrictEqual({
    transcript: [original],
    result: { decision: "current", presentedPlan: original },
  });
});

it("restores the terminal and rereads saved edits after editor failure", async () => {
  const f = fixture();
  f.editor.saves = edited;
  f.editor.failure = new Error("Editor failed");
  f.question().handleInput?.("\u0007");
  await f.until(() => f.screen.running);
  expect({
    transcript: f.transcript,
    warning: f.lines().some((line) => line.includes("Editor failed")),
    result: f.ui.result,
  }).toStrictEqual({
    transcript: [original, edited],
    warning: true,
    result: undefined,
  });
  for (const input of ["\t", "Revise the saved plan.", "\r"]) {
    f.question().handleInput?.(input);
  }
  expect(await f.pending).toStrictEqual({
    decision: "revise",
    presentedPlan: edited,
    feedback: "Revise the saved plan.",
  });
});

it.each(["missing", "empty", "template", "oversized"] as const)(
  "refuses approval of a %s plan after editing",
  async (state) => {
    const f = fixture();
    const saved = {
      missing: new Error("Plan is missing"),
      empty: { ...edited, content: "" },
      oversized: { ...edited, content: "x".repeat(200_001) },
      template: {
        ...edited,
        content:
          "# Implementation plan\n\nDraft the recommended approach here.\n",
      },
    };
    f.editor.saves = saved[state];
    f.question().handleInput?.("\u0007");
    await f.until(() => f.screen.running);
    f.question().handleInput?.("\r");
    f.question().handleInput?.("\u001B[B");
    f.question().handleInput?.("\r");
    expect(f.ui.result).toBeUndefined();
    f.question().handleInput?.("\u001B");
    expect(await f.pending).toStrictEqual({
      decision: "cancel",
      presentedPlan: original,
    });
  },
);

it("does not revive an aborted question after the editor returns", async () => {
  const f = fixture();
  const editor = Promise.withResolvers<void>();
  f.editor.closed = editor.promise;
  f.editor.saves = edited;
  f.question().handleInput?.("\u0007");
  f.abort.abort();
  const expected = { decision: "cancel", presentedPlan: original };
  expect(await f.pending).toStrictEqual(expected);
  editor.resolve();
  await f.until(() => f.screen.running);
  expect({
    transcript: f.transcript,
    result: f.ui.result,
  }).toStrictEqual({ transcript: [original], result: expected });
});
