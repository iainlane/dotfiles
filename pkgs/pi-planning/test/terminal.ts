import type { Terminal, TUI } from "@earendil-works/pi-tui";

/**
 * Resolves once `predicate` is true, checking it now and after each render
 * request. Renderers that finish their output asynchronously, such as Edit's
 * preview, request a render when they do.
 */
export function untilRendered(
  tui: TUI,
  predicate: () => boolean,
): Promise<void> {
  return new Promise((resolve) => {
    const requestRender = tui.requestRender.bind(tui);
    const check = () => {
      if (predicate()) {
        tui.requestRender = requestRender;
        resolve();
      }
    };
    tui.requestRender = (...args) => {
      requestRender(...args);
      check();
    };
    check();
  });
}

export class TestTerminal implements Terminal {
  columns = 80;
  rows = 24;
  kittyProtocolActive = false;
  private input: ((data: string) => void) | undefined;

  start(input: (data: string) => void): void {
    this.input = input;
  }

  stop(): void {
    this.input = undefined;
  }

  send(data: string): void {
    this.input?.(data);
  }

  async drainInput(): Promise<void> {}
  write(): void {}
  moveBy(): void {}
  hideCursor(): void {}
  showCursor(): void {}
  clearLine(): void {}
  clearFromCursor(): void {}
  clearScreen(): void {}
  setTitle(): void {}
  setProgress(): void {}
  setProgramStatus(): void {}
}
