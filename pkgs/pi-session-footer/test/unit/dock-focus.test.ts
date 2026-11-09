import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { Input } from "@earendil-works/pi-tui";
import { expect, it, vi } from "vitest";
import { DockFocus } from "#footer/ui/dock/dock-focus.ts";
import { editorFixture } from "#test/support/editor.ts";

type EditorFactory = NonNullable<
  ReturnType<ExtensionUIContext["getEditorComponent"]>
>;
function fixture() {
  const { tui } = editorFixture();
  const panel = new Input();
  const replacement = new Input();
  tui.addChild(panel);
  tui.addChild(replacement);
  tui.setFocus(panel);
  const originalFactory = vi.fn<EditorFactory>(() => {
    throw new Error("Unexpected editor construction");
  });
  const replacementFactory = vi.fn<EditorFactory>(() => {
    throw new Error("Unexpected editor construction");
  });
  let factory: EditorFactory = originalFactory;
  let active = true;
  const registration = vi.spyOn(tui, "addInputListener");
  const lease = DockFocus.attach(
    tui,
    () => factory,
    () => active,
  );
  const input = registration.mock.calls[0]?.[0];
  if (!lease || !input) {
    throw new Error("Expected a public focus subscription");
  }
  return {
    tui,
    panel,
    replacement,
    originalFactory,
    replacementFactory,
    lease,
    input,
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
    original: h.originalFactory.mock.calls,
    replacement: h.replacementFactory.mock.calls,
  }).toStrictEqual({
    result: undefined,
    panel: true,
    original: [],
    replacement: [],
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
