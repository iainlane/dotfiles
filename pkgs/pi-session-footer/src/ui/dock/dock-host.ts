import type {
  ExtensionUIContext,
  Theme,
} from "@earendil-works/pi-coding-agent";
import {
  Container,
  isFocusable,
  type Component,
  type Focusable,
  type TUI,
} from "@earendil-works/pi-tui";

import { DockGuard, type DockVisibility } from "./dock-guard.ts";

interface FocusTUI extends TUI {
  getFocusedComponent(): Component | null;
}

export function supportsFocus(tui: TUI): tui is FocusTUI {
  return (
    "getFocusedComponent" in tui &&
    typeof tui.getFocusedComponent === "function"
  );
}

export interface DockView extends Component {
  visibleControls?(): readonly string[];
  dispose?(): void;
}

type ViewFactory = (tui: TUI, theme: Theme, close: () => void) => DockView;
let nextId = 0;

class DockPanel extends Container implements Focusable {
  readonly capturesViewportInput = true;
  private hasFocus = false;
  closed = false;
  private locked = false;
  lastLines: readonly string[] = [];

  constructor(
    private readonly view: DockView,
    private readonly onReturn: () => void,
    private readonly onDispose: () => void,
    private readonly onRendered: () => void,
  ) {
    super();
    this.addChild(view);
  }

  get focused(): boolean {
    return this.hasFocus;
  }

  set focused(value: boolean) {
    this.hasFocus = value;
    if (isFocusable(this.view)) {
      this.view.focused = value && !this.closed && !this.locked;
    }
    if (value && this.closed) {
      queueMicrotask(this.onReturn);
    }
  }

  override render(width: number): string[] {
    if (this.closed) {
      return [];
    }
    const lines = super.render(width);
    this.lastLines = lines;
    this.onRendered();
    return lines;
  }

  visibleControls(): readonly string[] {
    return this.view.visibleControls?.() ?? this.lastLines;
  }

  setLocked(locked: boolean): void {
    this.locked = locked;
    this.focused = this.hasFocus;
  }

  handleInput(data: string): void {
    if (!this.closed && !this.locked) {
      this.view.handleInput?.(data);
    }
  }

  dispose(): void {
    this.onDispose();
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    if (isFocusable(this.view)) {
      this.view.focused = false;
    }
    this.view.dispose?.();
  }
}

export class DockHost {
  private readonly key = `session-footer:customise:${++nextId}`;
  private readonly completion = Promise.withResolvers<void>();
  private tui: FocusTUI | undefined;
  private previous: Component | null = null;
  private previousClearOnShrink: boolean | undefined;
  private panel: DockPanel | undefined;
  private guard: DockGuard | undefined;
  private closing = false;
  private removed = false;

  constructor(
    private readonly ui: Pick<ExtensionUIContext, "setWidget">,
    private readonly canRestore: () => boolean,
    private readonly visibility?: DockVisibility,
  ) {}

  open(factory: ViewFactory): Promise<void> {
    if (this.panel !== undefined || this.closing) {
      throw new Error("This footer editor has already been opened");
    }
    try {
      this.ui.setWidget(
        this.key,
        (tui, theme) => {
          if (!supportsFocus(tui)) {
            throw new Error("The terminal does not support docked focus");
          }
          this.tui = tui;
          this.previous = tui.getFocusedComponent();
          this.panel = new DockPanel(
            factory(tui, theme, () => this.close()),
            () => this.finish(),
            () => this.close(),
            () => this.guard?.rendered(),
          );
          if (this.visibility) {
            this.guard = new DockGuard(tui, this.visibility, {
              lines: () => this.panel?.visibleControls() ?? [],
              setLocked: (locked) => this.panel?.setLocked(locked),
              cancel: () => this.close(),
            });
          }
          this.previousClearOnShrink = tui.getClearOnShrink();
          tui.setClearOnShrink(true);
          tui.setFocus(this.panel);
          return this.panel;
        },
        { placement: "aboveEditor" },
      );
    } catch (error) {
      this.completion.reject(error);
    }
    return this.completion.promise;
  }

  close(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    this.guard?.dispose();
    this.panel?.close();
    this.finish();
  }

  private finish(): void {
    const { tui, panel } = this;
    if (this.removed) {
      return;
    }
    if (tui && panel) {
      const focused = tui.getFocusedComponent();
      // A nested overlay can still restore focus to this panel.
      if (focused !== panel && tui.hasOverlay()) {
        tui.requestRender();
        return;
      }
      if (focused === panel) {
        tui.setFocus(this.canRestore() ? this.previous : null);
      }
    }
    this.removed = true;
    this.ui.setWidget(this.key, undefined);
    if (tui && this.previousClearOnShrink !== undefined) {
      try {
        tui.renderNow();
      } finally {
        tui.setClearOnShrink(this.previousClearOnShrink);
      }
    }
    this.completion.resolve();
  }
}
