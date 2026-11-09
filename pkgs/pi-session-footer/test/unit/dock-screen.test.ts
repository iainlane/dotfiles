import { expect, it, vi } from "vitest";
import {
  containsRenderedBlock,
  visibleScreen,
} from "#footer/ui/dock/dock-screen.ts";
import { editorFixture } from "#test/support/editor.ts";

it.each([
  { screen: ["first", "second"], block: ["first", "second"], expected: true },
  { screen: ["first", "second"], block: ["first", "missing"], expected: false },
  { screen: ["first", "second"], block: [], expected: false },
  {
    screen: ["\u001B[31mfirst\u001B[0m  ", "second"],
    block: ["first", "second"],
    expected: true,
  },
  {
    screen: ["first", "third", "second"],
    block: ["first", "second"],
    expected: false,
  },
])(
  "recognises only a complete rendered block: $expected",
  ({ screen, block, expected }) => {
    expect(containsRenderedBlock(screen, block)).toBe(expected);
  },
);
it("reads the regular viewport without rendering any component again", () => {
  const { tui } = editorFixture();
  tui.terminal = { ...tui.terminal, rows: 2 };
  tui.restoreRenderState({
    previousLines: ["scrollback", "controls", "footer"],
    previousWidth: 80,
    previousHeight: 2,
    cursorRow: 2,
    hardwareCursorRow: 2,
    maxLinesRendered: 3,
    previousViewportTop: 1,
  });
  const render = vi.spyOn(tui, "render");
  expect({
    lines: visibleScreen(tui),
    renders: render.mock.calls,
  }).toStrictEqual({ lines: ["controls", "footer"], renders: [] });
});
