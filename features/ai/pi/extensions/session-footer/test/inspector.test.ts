import type { ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { expect, it, vi } from "vitest";
import { Inspector } from "../src/inspector.ts";
import { createSnapshot } from "../src/state.ts";

interface View {
  render(width: number): string[];
  invalidate(): void;
  handleInput(data: string): void;
  dispose(): void;
}

type Factory = (
  tui: { terminal: { rows: number }; requestRender(): void },
  theme: { fg(role: string, value: string): string },
  keys: unknown,
  done: () => void,
) => View;

function harness() {
  const views: {
    component: View;
    close: ReturnType<typeof vi.fn>;
    options: unknown;
    settle(): void;
  }[] = [];
  const select = vi.fn();
  const context = {
    mode: "tui",
    ui: {
      select,
      custom: (factory: Factory, options: unknown) =>
        new Promise<void>((resolve) => {
          const close = vi.fn(() => resolve());
          const component = factory(
            { terminal: { rows: 8 }, requestRender: () => {} },
            { fg: (_role, value) => value },
            undefined,
            close,
          );

          views.push({ component, close, options, settle: resolve });
        }),
    },
  } as unknown as ExtensionCommandContext;
  const inspector = new Inspector(() => createSnapshot(1000, "/work"));

  return { inspector, context, views, select };
}

it("keeps the current close handle after an older view is disposed", async () => {
  const { inspector, context, views } = harness();
  const first = inspector.open(context, "quota");
  const second = inspector.open(context, "usage");

  views[0]?.component.dispose();
  inspector.dispose();

  const closes = views.map((view) => view.close.mock.calls.length);

  for (const view of views) view.settle();

  await Promise.all([first, second]);

  expect(closes).toStrictEqual([1, 1]);
});

it("ignores a late section selection after shutdown", async () => {
  const { inspector, context, views, select } = harness();
  const selection = Promise.withResolvers<string>();

  select.mockReturnValue(selection.promise);

  const opened = inspector.open(context);

  inspector.dispose();
  selection.resolve("quota");
  await opened;

  expect(views).toStrictEqual([]);
});

it("scrolls details and closes with Escape", async () => {
  const { inspector, context, views } = harness();
  const opened = inspector.open(context, "quota");
  const view = views[0];

  if (!view) throw new Error("Expected an inspector view");

  const first = view.component.render(80);

  view.component.handleInput("\u001b[6~");

  const scrolled = view.component.render(80);

  view.component.handleInput("\u001b");
  await opened;
  view.component.dispose();

  expect({
    first: first[0],
    scrolled: scrolled[0],
    closes: view.close.mock.calls,
    options: view.options,
  }).toStrictEqual({
    first: "Footer: quota",
    scrolled: "Footer: quota",
    closes: [[]],
    options: {
      overlay: true,
      overlayOptions: { anchor: "top-center", width: "100%" },
    },
  });
  expect(scrolled).not.toStrictEqual(first);
});
