import { setImmediate } from "node:timers/promises";
import { expect, it } from "vitest";
import {
  CURSOR_MARKER,
  Editor,
  stripTerminalSequences,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";
import { ComposerEditor } from "#footer/ui/composer.ts";
import { editorFixture } from "#test/support/editor.ts";
import { fitFooterRow, type RenderFrame } from "#footer/rendering/render.ts";
import { layoutFooter } from "#test/support/layout.ts";
import { createSnapshot } from "#footer/domain/state.ts";
import { resolveSettings } from "#footer/configuration/settings.ts";

function harness(bottom: () => string = () => "") {
  const { tui, theme, keys } = editorFixture();
  const editor = new ComposerEditor(tui, theme, keys, {
    top: (width) => truncateToWidth("model · high", width, ""),
    bottom: (width) => truncateToWidth(bottom(), width, ""),
    completed() {},
    invalidate() {},
  });
  editor.focused = true;

  return editor;
}

function plain(lines: string[]): string[] {
  return lines.map((line) => stripTerminalSequences(line));
}

it.each([
  { bottom: "", height: 3 },
  { bottom: "status", height: 4 },
])(
  "reports the completed geometry with bottom '$bottom'",
  ({ bottom, height }) => {
    const { tui, theme, keys } = editorFixture();
    let geometry: unknown;
    const editor = new ComposerEditor(tui, theme, keys, {
      top: () => "top",
      bottom: () => bottom,
      completed: (completed) => {
        geometry = completed;
      },
      invalidate() {},
    });
    editor.setText("one\ntwo");
    const lines = editor.render(40);
    expect(geometry).toStrictEqual({ height, completionRows: 0, lines });
  },
);

const expectedTop: Record<string, unknown> = {
  "1": "…",
  "2": "…",
  "7": " /work",
  "8": "╭─ … ─╮",
};
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
      invalidate() {},
    });
    const output = plain(editor.render(width));
    if (!frame) {
      throw new Error("Expected render frame");
    }
    expect({
      completed,
      topBudget: frame.top.width,
      bottomBudget: frame.bottom.width,
      top: output[0],
      bottomDisplay: frame.bottom.text,
      fits: output.every((line) => visibleWidth(line) <= width),
    }).toStrictEqual({
      completed: true,
      topBudget: width < 8 ? width : width - 6,
      bottomBudget: width < 8 ? 0 : width - 6,
      top: expectedTop[String(width)],
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
  const [beforeCursor] = (lines.at(-1) ?? "").split(CURSOR_MARKER);

  expect(beforeCursor).toBe(`╰─ ${content.at(-1) ?? ""}`);
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

it("places a click in the draft after the configured padding", () => {
  const editor = harness();
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

  expect({
    text: editor.getText(),
    padding: editor.getPaddingX(),
  }).toStrictEqual({ text: "heXllo", padding: 1 });
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
    // The editor applies suggestions in promise callbacks, which all run
    // before the next macrotask.
    await setImmediate();
    expect(editor.isShowingAutocomplete()).toBe(true);
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
    const { tui, theme } = editorFixture();
    const base = new Editor(tui, theme, { paddingX: 3 });
    const text = Array.from({ length: 20 }, (_, index) => `line ${index}`);

    base.focused = true;
    for (const component of [editor, base]) {
      component.setText(text.join("\n"));

      if (top) {
        for (let index = 0; index < 20; index++) {
          component.handleInput("\u001B[A");
        }
      }
    }

    // The composer replaces the base editor's top border, draws its own
    // sides and corners around the base editor's rows, and drops an empty
    // bottom border by closing the frame on the last row.
    const rows = plain(base.render(60));
    const content = rows.slice(1, -1);
    const lastContent = content.at(-1) ?? "";
    const bottom = rows.at(-1) ?? "";

    expect(plain(editor.render(60))).toStrictEqual(
      top
        ? [
            `╭─ model · high${"─".repeat(42)} ─╮`,
            ...content.map((row) => `│${row.slice(1, -1)}│`),
            `╰${bottom.slice(1, -1)}╯`,
          ]
        : [
            `╭─ model · high ↑ 13 more${"─".repeat(32)} ─╮`,
            ...content.slice(0, -1).map((row) => `│${row.slice(1, -1)}│`),
            `╰─${lastContent.slice(2, -2)}─╯`,
          ],
    );
  },
);

const expectedRich: Record<string, unknown> = {
  "tasks 0/1": [
    "╭─ model · high────────────────────── ─╮",
    "│  draft 界                            │",
    "╰─ tasks 0/1───────────────────────── ─╯",
  ],
  " week 0% used": [
    "╭─ model · high────────────────────── ─╮",
    "│  draft 界                            │",
    "╰─  week 0% used──────────────────── ─╯",
  ],
};
const expectedCompact: Record<string, unknown> = {
  "tasks 0/1": [
    "╭─ model · high────────────────────── ─╮",
    "╰─ draft 界                           ─╯",
  ],
  " week 0% used": [
    "╭─ model · high────────────────────── ─╮",
    "╰─ draft 界                           ─╯",
  ],
};
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
      rich,
      compact,
      restored,
      text: editor.getText(),
    }).toStrictEqual({
      rich: expectedRich[status],
      compact: expectedCompact[status],
      restored: rich,
      text: "draft 界",
    });
  },
);
