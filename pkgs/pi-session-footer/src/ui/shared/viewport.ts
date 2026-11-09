import { ScrollView, Text } from "@earendil-works/pi-tui";

// Custom overlays do not run native layout traversal, so clip after updating ScrollView geometry.
export class DetailViewport {
  private readonly content = new Text("", 0, 0);
  private readonly scroll = new ScrollView(this.content, {
    scrollbar: "hidden",
  });
  total = 0;
  height = 1;
  get offset(): number {
    return this.scroll.scrollTop;
  }
  render(
    lines: string[],
    width: number,
    height: number,
    requestRender: () => void,
  ): string[] {
    this.content.setText(lines.join("\n"));
    const rendered = this.scroll.render(Math.max(1, width));
    this.total = rendered.length;
    this.height = Math.max(1, height);
    this.scroll.updateLayout(this.total, this.height, requestRender);
    return rendered.slice(this.offset, this.offset + this.height);
  }
  move(lines: number): void {
    this.scroll.scrollBy(lines);
  }
  reset(): void {
    this.scroll.scrollToStart();
  }
}
