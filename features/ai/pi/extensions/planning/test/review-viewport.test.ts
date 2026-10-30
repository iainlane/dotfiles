import { stripVTControlCharacters } from "node:util";
import {
  initTheme,
  ToolExecutionComponent,
} from "@earendil-works/pi-coding-agent";
import {
  matchesKey,
  ScrollView,
  TuiAltScreen,
  VStack,
  type Terminal,
} from "@earendil-works/pi-tui";
import { beforeAll, expect, it, vi } from "vitest";
import {
  reviewPlan,
  type ReviewContext,
  type ReviewResult,
} from "../src/review.ts";
import { renderPlanReview } from "../src/review-render.ts";

beforeAll(() => initTheme("dark", false));

class TestTerminal implements Terminal {
  columns = 80;
  rows = 24;
  kittyProtocolActive = false;
  private input: ((data: string) => void) | undefined;
  start(input: (data: string) => void): void {
    this.input = input;
  }
  stop(): void {
    this.input = undefined;
  }
  send(data: string): void {
    this.input?.(data);
  }
  async drainInput(): Promise<void> {}
  write(): void {}
  moveBy(): void {}
  hideCursor(): void {}
  showCursor(): void {}
  clearLine(): void {}
  clearFromCursor(): void {}
  clearScreen(): void {}
  setTitle(): void {}
  setProgress(): void {}
  setProgramStatus(): void {}
}

it.each([true, false])(
  "renders the full plan in collapsed native tool output with partial:%s",
  (isPartial) => {
    const terminal = new TestTerminal();
    const tui = new TuiAltScreen(terminal);
    const plan = {
      path: "/plans/review.md",
      revision: "reviewed",
      content: Array.from({ length: 45 }, (_, n) => `Paragraph ${n}`).join(
        "\n\n",
      ),
    };
    const component = new ToolExecutionComponent(
      "submit_plan",
      "review",
      {},
      {},
      { renderResult: renderPlanReview },
      tui,
      "/fixture",
    );
    component.updateResult(
      {
        content: [{ type: "text", text: "Review finished." }],
        details: {
          decision: isPartial ? "pending" : "current",
          presentedPlan: plan,
        },
        isError: false,
      },
      isPartial,
    );
    component.setExpanded(false);
    const output = component
      .render(80)
      .map((line) => stripVTControlCharacters(line))
      .join("\n");
    expect({
      beginning: output.includes("Paragraph 0"),
      ending: output.includes("Paragraph 44"),
      revision: output.includes("reviewed"),
      pendingFooter: output.includes("Awaiting approval"),
      finalSummary: output.includes("Review finished."),
    }).toStrictEqual({
      beginning: true,
      ending: true,
      revision: true,
      pendingFooter: false,
      finalSummary: !isPartial,
    });
  },
);

it("routes fullscreen page keys and wheel events to the plan while its question stays docked", async () => {
  const terminal = new TestTerminal();
  const tui = new TuiAltScreen(terminal);
  const abort = new AbortController();
  const plan = {
    path: "/plans/review.md",
    revision: "reviewed",
    content: Array.from({ length: 70 }, (_, n) => `Paragraph ${n}`).join(
      "\n\n",
    ),
  };
  let question:
    | ReturnType<Parameters<ReviewContext["ui"]["custom"]>[0]>
    | undefined;
  let document: ToolExecutionComponent | undefined;
  const ctx: ReviewContext = {
    mode: "tui",
    hasUI: true,
    ui: {
      select: vi.fn<ReviewContext["ui"]["select"]>(),
      custom: (factory) =>
        new Promise<ReviewResult>((resolve) => {
          question = factory(
            tui,
            { fg: (_color, text) => text },
            {
              matches: (input, action) =>
                action === "app.editor.external" && matchesKey(input, "ctrl+g"),
              getKeys: () => ["ctrl+g"],
            },
            resolve,
          );
        }),
    },
  };
  const pending = reviewPlan(
    ctx,
    {
      plan,
      signal: abort.signal,
      read: () => plan,
      present: (presentedPlan) => {
        document = new ToolExecutionComponent(
          "submit_plan",
          "review",
          {},
          {},
          { renderResult: renderPlanReview },
          tui,
          "/fixture",
        );
        document.updateResult(
          {
            content: [],
            details: { decision: "pending", presentedPlan },
            isError: false,
          },
          true,
        );
      },
    },
    async () => {},
  );
  if (!question || !document) {
    throw new Error("Expected both a plan transcript and a question.");
  }
  const transcript = new ScrollView(document, { primary: true, follow: "end" });
  const root = new VStack([
    { component: transcript, basis: 0, grow: 1, shrink: 1, minSize: 1 },
    { component: question, basis: "auto", grow: 0, shrink: 0 },
  ]);
  tui.setLayoutRoot(root);
  tui.setFocus(question);
  try {
    tui.start();
    tui.renderNow(true);
    const dock = question.render(terminal.columns);
    const bottom = transcript.scrollTop;
    terminal.send("\u001B[5~");
    tui.renderNow();
    const pageUp = transcript.scrollTop;
    terminal.send("\u001B[6~");
    tui.renderNow();
    const pageDown = transcript.scrollTop;
    terminal.send("\u001B[<64;5;5M");
    tui.renderNow();
    expect({
      pageUp: pageUp < bottom,
      pageDown: pageDown > pageUp,
      wheel: transcript.scrollTop < pageDown,
      dock: question.render(terminal.columns),
      rows: transcript.viewportHeight + dock.length,
    }).toStrictEqual({
      pageUp: true,
      pageDown: true,
      wheel: true,
      dock,
      rows: terminal.rows,
    });
  } finally {
    abort.abort();
    question.dispose();
    tui.stop();
    await pending;
  }
});
