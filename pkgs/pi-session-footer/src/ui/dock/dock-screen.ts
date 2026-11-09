import {
  stripTerminalSequences,
  type TUI,
  type TuiMainScreenRenderState,
} from "@earendil-works/pi-tui";

interface FullscreenSnapshot extends TUI {
  getScreenLines(): string[];
}
interface RegularSnapshot extends TUI {
  captureRenderState(): TuiMainScreenRenderState;
}
function isFullscreenSnapshot(tui: TUI): tui is FullscreenSnapshot {
  return "getScreenLines" in tui && typeof tui.getScreenLines === "function";
}
function isRegularSnapshot(tui: TUI): tui is RegularSnapshot {
  return (
    "captureRenderState" in tui && typeof tui.captureRenderState === "function"
  );
}
export function visibleScreen(tui: TUI): readonly string[] | undefined {
  if (isFullscreenSnapshot(tui)) {
    return tui.getScreenLines();
  }
  if (isRegularSnapshot(tui)) {
    const state = tui.captureRenderState();
    return state.previousLines.slice(
      state.previousViewportTop,
      state.previousViewportTop + tui.terminal.rows,
    );
  }
  return undefined;
}
export function containsRenderedBlock(
  screen: readonly string[],
  block: readonly string[],
): boolean {
  if (block.length === 0) {
    return false;
  }
  const plain = screen.map((line) => stripTerminalSequences(line).trimEnd());
  const expected = block.map((line) => stripTerminalSequences(line).trimEnd());
  return plain.some((_line, start) =>
    expected.every((line, index) => plain[start + index] === line),
  );
}
