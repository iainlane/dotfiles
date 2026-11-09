import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import type { Component, TUI } from "@earendil-works/pi-tui";
import { supportsFocus } from "./dock-host.ts";

type EditorFactory = ReturnType<ExtensionUIContext["getEditorComponent"]>;
interface FocusScreen extends TUI {
  getFocusedComponent(): Component | null;
}
interface ReturnTarget {
  factory: EditorFactory;
  component: Component | null;
}
export class DockFocus {
  private readonly panel: Component | null;
  private factory: EditorFactory;
  private target: ReturnTarget | undefined;
  private readonly unsubscribe: () => void;
  private closed = false;

  private constructor(
    private readonly tui: FocusScreen,
    private readonly editor: () => EditorFactory,
    private readonly active: () => boolean,
  ) {
    this.panel = tui.getFocusedComponent();
    this.factory = editor();
    this.unsubscribe = tui.addInputListener(() => this.beforeInput());
  }
  static attach(
    tui: TUI,
    editor: () => EditorFactory,
    active: () => boolean,
  ): DockFocus | undefined {
    if (!supportsFocus(tui)) {
      return undefined;
    }
    return new DockFocus(tui, editor, active);
  }
  private beforeInput(): undefined {
    if (this.closed || !this.active() || this.tui.hasOverlay()) {
      return;
    }
    const factory = this.editor();
    const focused = this.tui.getFocusedComponent();
    if (factory !== this.factory && focused !== this.panel) {
      this.factory = factory;
      this.target = { factory, component: focused };
      this.tui.setFocus(this.panel);
    }
  }
  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.unsubscribe();
    const target = this.target;
    if (
      target !== undefined &&
      this.active() &&
      target.factory === this.editor() &&
      this.tui.getFocusedComponent() === this.panel
    ) {
      this.tui.setFocus(target.component);
    }
  }
}
