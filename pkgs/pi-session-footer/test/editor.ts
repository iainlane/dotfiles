import { KeybindingsManager } from "../node_modules/@earendil-works/pi-coding-agent/dist/core/keybindings.js";
import {
  TuiMainScreen,
  type EditorTheme,
  type Terminal,
} from "@earendil-works/pi-tui";

const noop = () => {};
export function editorFixture() {
  const terminal: Terminal = {
    rows: 24,
    columns: 80,
    kittyProtocolActive: false,
    start: noop,
    stop: noop,
    drainInput: async () => {},
    write: noop,
    moveBy: noop,
    hideCursor: noop,
    showCursor: noop,
    clearLine: noop,
    clearFromCursor: noop,
    clearScreen: noop,
    setTitle: noop,
    setProgress: noop,
    setProgramStatus: noop,
  };
  const theme: EditorTheme = {
    borderColor: (value) => value,
    selectList: {
      selectedPrefix: (value) => value,
      selectedText: (value) => value,
      description: (value) => value,
      scrollInfo: (value) => value,
      noMatch: (value) => value,
    },
  };
  return {
    tui: new TuiMainScreen(terminal),
    theme,
    keys: new KeybindingsManager(),
  };
}
