import { expect, it, vi } from "vitest";
import { reviewPlan, type ReviewDecision } from "../src/review.ts";

type ReviewContext = Parameters<typeof reviewPlan>[0];
const createDocument = (content: string) => ({
  render: () => content.split("\n"),
  invalidate() {},
});

type ReviewComponent = ReturnType<Parameters<ReviewContext["ui"]["custom"]>[0]>;

it.each(["a", "f", "r", "\u001B"])(
  "reviews the TUI document with %s",
  async (key) => {
    const controller = new AbortController();
    const components: ReviewComponent[] = [];
    const done = vi.fn<(decision: ReviewDecision) => void>();
    const ctx: ReviewContext = {
      mode: "tui",
      hasUI: true,
      ui: {
        select: vi.fn<ReviewContext["ui"]["select"]>(),
        custom: (factory: Parameters<ReviewContext["ui"]["custom"]>[0]) =>
          new Promise<ReviewDecision>((resolve) => {
            components.push(
              factory(
                { terminal: { rows: 10 }, requestRender: vi.fn<() => void>() },
                {},
                {},
                (decision) => {
                  done(decision);
                  resolve(decision);
                },
              ),
            );
          }),
      },
    };
    const pending = reviewPlan(
      ctx,
      {
        path: "/plans/document.md",
        revision: "reviewed-revision",
        content: Array.from({ length: 20 }, (_, index) => `Line ${index}`).join(
          "\n\n",
        ),
      },
      controller.signal,
      createDocument,
    );
    const component = components[0];
    if (component === undefined) {
      throw new Error("Expected an open plan review");
    }
    const first = component.render(50);
    component.handleInput?.("\u001B[B");
    const scrolled = component.render(50);
    expect({
      changed: first.join() !== scrolled.join(),
      revision: scrolled[1],
    }).toStrictEqual({
      changed: true,
      revision: "Revision: reviewed-revision",
    });
    component.handleInput?.(key);
    controller.abort();
    expect(await pending).toBe(
      key === "a"
        ? "current"
        : key === "f"
          ? "fresh"
          : key === "r"
            ? "revise"
            : "cancel",
    );
    expect(done).toHaveBeenCalledTimes(1);
  },
);

it("cancels an open TUI review on interruption", async () => {
  const controller = new AbortController();
  const custom = vi.fn<ReviewContext["ui"]["custom"]>(
    (factory) =>
      new Promise((resolve) => {
        factory(
          { terminal: { rows: 20 }, requestRender: vi.fn<() => void>() },
          {},
          {},
          resolve,
        );
      }),
  );
  const ctx: ReviewContext = {
    mode: "tui",
    hasUI: true,
    ui: { custom, select: vi.fn<ReviewContext["ui"]["select"]>() },
  };
  const pending = reviewPlan(
    ctx,
    { path: "/plan", revision: "revision", content: "Plan" },
    controller.signal,
    createDocument,
  );
  controller.abort();
  expect(await pending).toBe("cancel");
});
