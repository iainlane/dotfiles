import type { Theme } from "@earendil-works/pi-coding-agent";
import { Text, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { DetailViewport } from "./viewport.ts";

export interface SelectionRow {
  key: string;
  value: string;
  description?: string;
}
interface RowBlock {
  key: string;
  start: number;
  end: number;
}
type Movement = "up" | "down" | "pageUp" | "pageDown";
export class SelectionViewport {
  private readonly viewport = new DetailViewport();
  private blocks: RowBlock[] = [];
  private key: string | undefined;
  get selected(): string | undefined {
    return this.key;
  }
  get position(): { current: number; total: number } {
    return {
      current: Math.max(
        0,
        this.blocks.findIndex((block) => block.key === this.key) + 1,
      ),
      total: this.blocks.length,
    };
  }
  select(key: string): void {
    this.key = key;
  }
  private rowLines(
    row: SelectionRow,
    width: number,
    theme: Pick<Theme, "fg">,
  ): string[] {
    const contentWidth = Math.max(1, width - 2);
    const prefix = row.key === this.key ? theme.fg("accent", "› ") : "  ";
    const value = truncateToWidth(row.value, contentWidth, "…");
    const description = row.description ?? "";
    if (description === "") {
      return [truncateToWidth(prefix + value, width)];
    }
    if (visibleWidth(value) + 2 + visibleWidth(description) <= contentWidth) {
      return [prefix + value + "  " + theme.fg("muted", description)];
    }
    return [
      prefix + value,
      ...new Text(description, 0, 0)
        .render(contentWidth)
        .map((line) => "  " + theme.fg("muted", line.trimEnd())),
    ].map((line) => truncateToWidth(line, width));
  }
  render(
    rows: readonly SelectionRow[],
    width: number,
    height: number,
    theme: Pick<Theme, "fg">,
    requestRender: () => void,
  ): string[] {
    if (!rows.some((row) => row.key === this.key)) {
      this.key = rows[0]?.key;
    }
    this.blocks = [];
    if (width <= 0 || height <= 0) {
      return [];
    }
    const lines: string[] = [];
    for (const row of rows) {
      const rendered = this.rowLines(row, width, theme);
      this.blocks.push({
        key: row.key,
        start: lines.length,
        end: lines.length + rendered.length,
      });
      lines.push(...rendered);
    }
    const initial = this.viewport.render(lines, width, height, requestRender);
    const block = this.blocks.find((value) => value.key === this.key);
    if (block === undefined) {
      return initial;
    }
    const offset = this.viewport.offset;
    let target = offset;
    if (block.start < offset) {
      target = block.start;
    }
    if (block.end > offset + height) {
      target = Math.min(block.start, block.end - height);
    }
    if (target === offset) {
      return initial;
    }
    this.viewport.move(target - offset);
    return this.viewport.render(lines, width, height, requestRender);
  }
  move(direction: Movement): void {
    if (this.blocks.length === 0) {
      return;
    }
    const current = Math.max(
      0,
      this.blocks.findIndex((block) => block.key === this.key),
    );
    let next = current;
    switch (direction) {
      case "up":
        next = Math.max(0, current - 1);
        break;
      case "down":
        next = Math.min(this.blocks.length - 1, current + 1);
        break;
      case "pageUp": {
        const target =
          (this.blocks[current]?.start ?? 0) - this.viewport.height;
        next = Math.max(
          0,
          this.blocks.findLastIndex((block) => block.start <= target),
        );
        this.viewport.move(-this.viewport.height);
        break;
      }
      case "pageDown": {
        const target =
          (this.blocks[current]?.start ?? 0) + this.viewport.height;
        const index = this.blocks.findIndex((block) => block.start >= target);
        next = index < 0 ? this.blocks.length - 1 : index;
        this.viewport.move(this.viewport.height);
        break;
      }
    }
    this.key = this.blocks[next]?.key;
  }
}
