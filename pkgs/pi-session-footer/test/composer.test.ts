import { expect, it, vi } from "vitest";
import {
  CURSOR_MARKER,
  stripTerminalSequences,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";
import { ComposerEditor } from "../src/composer.ts";
import { editorFixture } from "./editor.ts";
import { layoutFooter, fitFooterRow, type RenderFrame } from "../src/render.ts";
import { createSnapshot } from "../src/state.ts";
import { resolveSettings } from "../src/settings.ts";

function harness(bottom: () => string = () => "") {
  const { tui, theme, keys } = editorFixture();
  const editor = new ComposerEditor(tui, theme, keys, {
    top: (width) => truncateToWidth("model · high", width, ""),
    bottom: (width) => truncateToWidth(bottom(), width, ""),
    completed() {},
  });
  editor.focused = true;

  return editor;
}

function plain(lines: string[]): string[] {
  return lines.map((line) => stripTerminalSequences(line));
}

it.each([1, 2, 7, 8])(
  "records only the actual status budgets at %i columns",
  (width) => {
    const { tui, theme, keys } = editorFixture();
    const state = createSnapshot(1000, "/work");
    const settings = resolveSettings({
      "top-left": ["directory"],
      "top-right": [],
      "bottom-left": ["directory"],
      "bottom-right": [],
    });
    let frame: RenderFrame | undefined;
    let completed = false;
    const editor = new ComposerEditor(tui, theme, keys, {
      top: (budget) => {
        frame = layoutFooter(state, { top: budget, bottom: 0 }, { settings });
        return frame.top.text;
      },
      bottom: (budget) => {
        if (!frame) {
          throw new Error("Expected top render");
        }
        const bottom = fitFooterRow(frame, settings, {
          placement: "bottom",
          width: budget,
        });
        frame = {
          ...frame,
          bottom: bottom.row,
          decisions: [
            ...frame.decisions.filter((d) => d.region.startsWith("top-")),
            ...bottom.decisions,
          ],
        };
        return bottom.row.text;
      },
      completed: () => {
        completed = true;
      },
    });
    const output = plain(editor.render(width));
    if (!frame) {
      throw new Error("Expected render frame");
    }
    expect({
      completed,
      topBudget: frame.top.width,
      bottomBudget: frame.bottom.width,
      topDisplayed: output[0]?.includes(stripTerminalSequences(frame.top.text)),
      bottomDisplay: frame.bottom.text,
      fits: output.every((line) => visibleWidth(line) <= width),
    }).toStrictEqual({
      completed: true,
      topBudget: width < 8 ? width : width - 6,
      bottomBudget: width < 8 ? 0 : width - 6,
      topDisplayed: true,
      bottomDisplay: width < 8 ? "" : frame.bottom.text,
      fits: true,
    });
    expect(
      frame.decisions
        .filter((d) => d.region.startsWith("bottom-"))
        .map(({ decision }) => decision),
    ).toStrictEqual([width < 8 ? "omitted" : "truncated"]);
  },
);
it.each([
  { text: "", content: [""] },
  { text: "hello", content: ["hello"] },
  { text: "first\nsecond", content: ["first", "second"] },
  { text: "界é", content: ["界é"] },
])("renders a compact rounded frame for '$text'", ({ text, content }) => {
  const editor = harness();
  editor.setText(text);
  const width = 32;
  const lines = editor.render(width);

  expect({ lines: plain(lines), text: editor.getText() }).toStrictEqual({
    lines: [
      `╭─ model · high${"─".repeat(14)} ─╮`,
      ...content.map((line, index) => {
        const body = line + " ".repeat(width - 6 - visibleWidth(line));

        return index === content.length - 1 ? `╰─ ${body} ─╯` : `│  ${body}  │`;
      }),
    ],
    text,
  });
  expect(lines.join("\n")).toContain(CURSOR_MARKER);
});

it.each([0, 1, 2, 5, 7, 8, 10, 30, 80])(
  "preserves the draft without overflowing %i columns",
  (width) => {
    const editor = harness();
    const text = "界é this draft wraps onto several lines";
    editor.setText(text);
    const lines = editor.render(width);

    expect({
      text: editor.getText(),
      fits: lines.every((line) => visibleWidth(line) <= width),
    }).toStrictEqual({ text, fits: true });
  },
);

it("preserves input columns and inherited keyboard and paste actions", () => {
  const editor = harness();
  const actions: string[] = [];
  editor.onEscape = () => actions.push("interrupt");
  editor.onCtrlD = () => actions.push("exit");
  editor.onPasteImage = () => actions.push("image");
  editor.onAction("app.thinking.cycle", () => actions.push("thinking"));
  editor.handleInput("\u001B");
  editor.handleInput("\u0004");
  editor.handleInput("\u0016");
  editor.handleInput("\u001B[Z");
  editor.setPaddingX(1);
  editor.setText("hello");
  editor.render(40);
  editor.handleMouse({
    type: "click",
    button: "left",
    x: 6,
    y: 1,
    screenX: 6,
    screenY: 1,
    width: 40,
    height: 2,
    shift: false,
    alt: false,
    ctrl: false,
  });
  editor.handleInput("X");
  const edited = editor.getText();
  editor.addToHistory("saved draft");
  editor.setText("");
  editor.handleInput("\u001B[A");

  expect({
    actions,
    edited,
    text: editor.getText(),
    padding: editor.getPaddingX(),
  }).toStrictEqual({
    actions: ["interrupt", "exit", "image", "thinking"],
    edited: "heXllo",
    text: "saved draft",
    padding: 1,
  });
});

it.each([
  {
    mode: "keyboard",
    select: (editor: ComposerEditor) => {
      editor.handleInput("\u001B[B");
      editor.handleInput("\t");
    },
  },
  {
    mode: "mouse",
    select: (editor: ComposerEditor, height: number) => {
      editor.handleMouse({
        type: "click",
        button: "left",
        x: 5,
        y: 3,
        screenX: 5,
        screenY: 3,
        width: 40,
        height,
        shift: false,
        alt: false,
        ctrl: false,
      });
    },
  },
])(
  "preserves $mode completion after compacting the bottom border",
  async ({ select }) => {
    const editor = harness();
    editor.setAutocompleteProvider({
      getSuggestions: async () => ({
        items: [
          { value: "/alpha", label: "/alpha" },
          { value: "/another", label: "/another" },
        ],
        prefix: "/a",
      }),
      applyCompletion: (_lines, _line, _col, item) => ({
        lines: [item.value],
        cursorLine: 0,
        cursorCol: item.value.length,
      }),
      shouldTriggerFileCompletion: () => false,
    });
    editor.handleInput("/");
    editor.handleInput("a");
    await vi.waitFor(() => expect(editor.isShowingAutocomplete()).toBe(true));
    const lines = editor.render(40);

    expect(plain(lines).slice(0, 2)).toStrictEqual([
      `╭─ model · high${"─".repeat(22)} ─╮`,
      `╰─ /a${" ".repeat(32)} ─╯`,
    ]);
    select(editor, lines.length);

    expect(editor.getText()).toBe("/another");
  },
);

it.each([false, true])(
  "preserves overflow indicators with cursor at top=%s",
  (top) => {
    const editor = harness();
    editor.setText(
      Array.from({ length: 20 }, (_, index) => `line ${index}`).join("\n"),
    );

    if (top) {
      for (let index = 0; index < 20; index++) {
        editor.handleInput("\u001B[A");
      }
    }

    const lines = plain(editor.render(60));

    expect({
      above: lines[0]?.includes("↑ 13 more"),
      below: lines.at(-1)?.includes("↓ 13 more"),
      rows: lines.length,
    }).toStrictEqual({ above: !top, below: top, rows: top ? 9 : 8 });
  },
);

it.each(["tasks 0/1", " week 0% used"])(
  "keeps a separate populated bottom border: %s",
  (status) => {
    let bottom = status;
    const editor = harness(() => bottom);
    editor.setText("draft 界");
    const rich = plain(editor.render(40));
    bottom = "";
    const compact = plain(editor.render(40));
    bottom = status;
    const restored = plain(editor.render(40));
    expect({
      rich: rich.length,
      compact: compact.length,
      restored,
      text: editor.getText(),
      status: rich.at(-1)?.includes(status),
    }).toStrictEqual({
      rich: 3,
      compact: 2,
      restored: rich,
      text: "draft 界",
      status: true,
    });
  },
);
