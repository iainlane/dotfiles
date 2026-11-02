import type { Terminal } from "@earendil-works/pi-tui";

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
