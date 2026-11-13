import {
  CustomEditor,
  type KeybindingsManager,
} from "@earendil-works/pi-coding-agent";
import {
  sliceByColumn,
  truncateToWidth,
  visibleWidth,
  type EditorTheme,
  type TUI,
  type TuiMouseEvent,
  type TuiMouseEventResult,
} from "@earendil-works/pi-tui";

export interface ComposerGeometry {
  height: number;
  completionRows: number;
  lines: readonly string[];
}
export interface ComposerBorders {
  top(width: number): string;
  bottom(width: number): string;
  completed(geometry: ComposerGeometry): void;
}
export class ComposerEditor extends CustomEditor {
  private userPadding = 0;
  private bottomBorder = "";
  private hiddenBelow = 0;
  private completionRow = 0;
  private compact = false;
  private bottomContent = false;
  private displayWidth = 0;
  private readonly borders: ComposerBorders;

  constructor(
    tui: TUI,
    theme: EditorTheme,
    keybindings: KeybindingsManager,
    borders: ComposerBorders,
  ) {
    super(tui, theme, keybindings, { paddingX: 3 });
    this.borders = borders;
  }

  override getPaddingX(): number {
    return this.userPadding;
  }

  override setPaddingX(padding: number): void {
    this.userPadding = Math.max(0, Math.trunc(padding));
    super.setPaddingX(this.userPadding + 3);
  }

  protected override renderTopBorder(
    width: number,
    hiddenLineCount: number,
  ): string {
    width = Math.min(width, this.displayWidth);
    if (width < 8) {
      if (hiddenLineCount > 0) {
        this.borders.top(0);
        return super.renderTopBorder(width, hiddenLineCount);
      }
      return this.borders.top(width);
    }

    const available = width - 6;
    const overflow = hiddenLineCount > 0 ? ` ↑ ${hiddenLineCount} more` : "";
    const status = this.borders.top(
      Math.max(0, available - visibleWidth(overflow)),
    );
    const content = truncateToWidth(
      status + this.borderColor(overflow),
      available,
      "",
    );
    const fill = this.borderColor(
      "─".repeat(Math.max(0, available - visibleWidth(content))),
    );

    return `${this.borderColor("╭─ ")}${content}${fill}${this.borderColor(" ─╮")}`;
  }

  protected override renderBottomBorder(
    width: number,
    hiddenLineCount: number,
  ): string {
    width = Math.min(width, this.displayWidth);
    this.hiddenBelow = hiddenLineCount;
    const overflow = hiddenLineCount > 0 ? ` ↓ ${hiddenLineCount} more` : "";
    const available = width < 8 ? 0 : Math.max(0, width - 6);
    const status = this.borders.bottom(
      Math.max(0, available - visibleWidth(overflow)),
    );
    this.bottomContent = visibleWidth(status.trim()) > 0;
    this.bottomBorder =
      this.bottomContent && width >= 8
        ? `${this.borderColor("╰─ ")}${status}${this.borderColor(overflow)}${this.borderColor("─".repeat(Math.max(0, available - visibleWidth(status) - visibleWidth(overflow))))}${this.borderColor(" ─╯")}`
        : super.renderBottomBorder(width, hiddenLineCount);

    return this.bottomBorder;
  }

  override render(width: number): string[] {
    width = Math.max(0, Math.trunc(width));
    this.compact = false;
    this.displayWidth = width;

    if (width === 0) {
      return [];
    }

    const renderWidth = Math.max(3, width);
    const padding =
      width < 8
        ? 0
        : Math.min(this.userPadding + 3, Math.floor((renderWidth - 2) / 2));
    super.setPaddingX(padding);

    const lines = super.render(renderWidth);
    const bottom = lines.lastIndexOf(this.bottomBorder);
    this.completionRow = bottom + 1;
    if (width < 8 || bottom < 2) {
      const clipped = lines.map((line) => truncateToWidth(line, width, ""));
      this.borders.completed({
        height: clipped.length,
        lines: clipped,
        completionRows: Math.max(0, clipped.length - this.completionRow),
      });
      return clipped;
    }

    this.compact = !this.bottomContent && this.hiddenBelow === 0;

    for (let index = 1; index < bottom; index++) {
      const line = lines[index];

      if (line === undefined) {
        continue;
      }

      lines[index] =
        this.compact && index === bottom - 1
          ? `${this.borderColor("╰─")}${line.slice(2, -2)}${this.borderColor("─╯")}`
          : `${this.borderColor("│")}${line.slice(1, -1)}${this.borderColor("│")}`;
    }

    if (this.compact) {
      lines.splice(bottom, 1);
      this.completionRow--;
      this.borders.completed({
        height: lines.length,
        lines,
        completionRows: Math.max(0, lines.length - this.completionRow),
      });
      return lines;
    }

    if (!this.bottomContent) {
      lines[bottom] =
        this.borderColor("╰") +
        sliceByColumn(this.bottomBorder, 1, width - 2, true) +
        this.borderColor("╯");
    }

    this.borders.completed({
      height: lines.length,
      lines,
      completionRows: Math.max(0, lines.length - this.completionRow),
    });
    return lines;
  }

  override handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (this.compact && event.y >= this.completionRow) {
      return super.handleMouse({
        ...event,
        y: event.y + 1,
        height: event.height + 1,
      });
    }

    return super.handleMouse(event);
  }
}
