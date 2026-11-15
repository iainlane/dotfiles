import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import {
  Input,
  TuiMainScreen,
  type TuiInputListener,
  type TuiInputListenerResult,
} from "@earendil-works/pi-tui";
import { expect, it } from "vitest";
import { DockFocus } from "#footer/ui/dock/dock-focus.ts";
import { editorFixture } from "#test/support/editor.ts";

type EditorFactory = NonNullable<
  ReturnType<ExtensionUIContext["getEditorComponent"]>
>;
class InputTui extends TuiMainScreen {
  private readonly listeners = new Set<TuiInputListener>();

  override addInputListener(listener: TuiInputListener): () => void {
    this.listeners.add(listener);
    const remove = super.addInputListener(listener);
    return () => {
      this.listeners.delete(listener);
      remove();
    };
  }

  override removeInputListener(listener: TuiInputListener): void {
    this.listeners.delete(listener);
    super.removeInputListener(listener);
  }

  send(data: string): TuiInputListenerResult | undefined {
    for (const listener of this.listeners) {
      const result = listener(data);
      if (result !== undefined) {
        return result;
      }
    }
    return undefined;
  }
}

const unexpected: EditorFactory = () => {
  throw new Error("Unexpected editor construction");
};

function fixture() {
  const tui = new InputTui(editorFixture().tui.terminal);
  const panel = new Input();
  const replacement = new Input();
  tui.addChild(panel);
  tui.addChild(replacement);
  tui.setFocus(panel);
  const replacementFactory: EditorFactory = (...args) => unexpected(...args);
  let factory = unexpected;
  let active = true;
  const lease = DockFocus.attach(
    tui,
    () => factory,
    () => active,
  );
  if (!lease) {
    throw new Error("Expected a public focus subscription");
  }
  return {
    tui,
    panel,
    replacement,
    lease,
    input: (data: string) => tui.send(data),
    replace: () => {
      factory = replacementFactory;
      tui.setFocus(replacement);
    },
    supersede: () => {
      active = false;
    },
  };
}
it("keeps the controls focused after replacement and returns to the replacement without constructing an editor", () => {
  const h = fixture();
  h.replace();
  const result = h.input("\r");
  expect({
    result,
    panel: h.tui.getFocusedComponent() === h.panel,
  }).toStrictEqual({
    result: undefined,
    panel: true,
  });
  h.lease.close();
  h.lease.close();
  expect(h.tui.getFocusedComponent()).toBe(h.replacement);
});
it("defers focus changes while a nested overlay is present", () => {
  const h = fixture();
  const overlay = h.tui.showOverlay(new Input());
  h.replace();
  h.input("\r");
  expect(h.tui.getFocusedComponent()).toBe(h.replacement);
  overlay.hide();
  h.input("\r");
  expect(h.tui.getFocusedComponent()).toBe(h.panel);
  h.lease.close();
  expect(h.tui.getFocusedComponent()).toBe(h.replacement);
});
it("leaves a superseding interaction unchanged after disposal and stale input", () => {
  const h = fixture();
  h.replace();
  h.input("\r");
  const next = new Input();
  h.supersede();
  h.tui.setFocus(next);
  h.input("\r");
  h.lease.close();
  h.input("\r");
  expect(h.tui.getFocusedComponent()).toBe(next);
});
