import type { Theme } from "@earendil-works/pi-coding-agent";
import {
  truncateToWidth,
  type OverlayHandle,
  type TUI,
} from "@earendil-works/pi-tui";
import { containsRenderedBlock, visibleScreen } from "./dock-screen.ts";

type GuardAction = "tui.select.confirm" | "tui.select.cancel";
export interface DockVisibility {
  previewLines(): readonly string[];
  setPreviewVisible(visible: boolean): void;
  theme(): Pick<Theme, "fg">;
  keys: {
    matches(data: string, action: GuardAction): boolean;
    getKeys(action: GuardAction): readonly string[];
  };
}
interface DockTarget {
  lines(): readonly string[];
  setLocked(locked: boolean): void;
  cancel(): void;
}
export class DockGuard {
  private queued = false;
  private closed = false;
  private retrying = false;
  private preview = true;
  private overlay: OverlayHandle | undefined;
  private unsupported = false;

  constructor(
    private readonly tui: TUI,
    private readonly options: DockVisibility,
    private readonly target: DockTarget,
  ) {}

  rendered(): void {
    if (this.queued || this.closed) {
      return;
    }
    this.queued = true;
    // Public screen snapshots are updated after component rendering returns.
    queueMicrotask(() => {
      this.queued = false;
      this.check();
    });
  }

  dispose(): void {
    this.closed = true;
    this.overlay?.hide();
    this.overlay = undefined;
  }

  private check(): void {
    if (this.closed || this.tui.hasOverlay()) {
      return;
    }
    const screen = visibleScreen(this.tui);
    this.unsupported = screen === undefined;
    const preview = this.options.previewLines();
    if (
      screen &&
      containsRenderedBlock(screen, this.target.lines()) &&
      (preview.length === 0 || containsRenderedBlock(screen, preview))
    ) {
      if (this.retrying) {
        this.retrying = false;
        this.overlay?.hide();
        this.overlay = undefined;
        this.target.setLocked(false);
        this.tui.requestRender();
      }
      return;
    }
    this.pause();
  }

  private pause(): void {
    this.retrying = false;
    this.target.setLocked(true);
    if (this.preview) {
      this.preview = false;
      this.options.setPreviewVisible(false);
    }
    if (this.overlay) {
      this.overlay.setHidden(false);
      return;
    }
    this.overlay = this.tui.showOverlay(
      {
        render: (width) => {
          const theme = this.options.theme();
          const confirm = this.options.keys
            .getKeys("tui.select.confirm")
            .join("/");
          const cancel = this.options.keys
            .getKeys("tui.select.cancel")
            .join("/");
          const lines = [
            theme.fg("accent", "Footer › Customise"),
            theme.fg(
              "warning",
              this.unsupported
                ? "Preview unavailable in this terminal"
                : "More room needed",
            ),
            "Resize the terminal to resume editing.",
            `${confirm} retry · ${cancel} cancel`,
          ];
          if (this.tui.terminal.rows < lines.length) {
            return [truncateToWidth(`Resize · ${cancel} cancel`, width)];
          }
          return lines.map((line) => truncateToWidth(line, width));
        },
        invalidate() {},
        handleInput: (data) => {
          if (this.options.keys.matches(data, "tui.select.cancel")) {
            this.target.cancel();
            return;
          }
          if (this.options.keys.matches(data, "tui.select.confirm")) {
            this.retrying = true;
            this.preview = true;
            this.options.setPreviewVisible(true);
            this.overlay?.setHidden(true);
            this.tui.requestRender();
          }
        },
      },
      { anchor: "top-center", width: "100%", maxHeight: "100%" },
    );
    this.tui.requestRender();
  }
}
