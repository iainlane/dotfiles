import { stripVTControlCharacters } from "node:util";
import {
  initTheme,
  ToolExecutionComponent,
} from "@earendil-works/pi-coding-agent";
import {
  CURSOR_MARKER,
  matchesKey,
  ScrollView,
  TuiAltScreen,
  VStack,
} from "@earendil-works/pi-tui";
import { beforeAll, expect, it, vi } from "vitest";
import {
  reviewPlan,
  type ReviewContext,
  type ReviewResult,
} from "../src/review.ts";
import { renderPlanDocument, renderPlanReview } from "../src/review-render.ts";
import { TestTerminal } from "./terminal.ts";

beforeAll(() => initTheme("dark", false));

it.each([
  { text: "\u001B[8mhidden\u001B[0m", visible: "\\u001b[8mhidden\\u001b[0m" },
  { text: "before\rhidden\bafter", visible: "before\\u000dhidden\\u0008after" },
  { text: "before\u202Eafter", visible: "before\\u202eafter" },
])(
  "visibly escapes untrusted controls in plan text and paths: $visible",
  ({ text, visible }) => {
    const plan = {
      path: `/plans/${text}.md`,
      revision: "canonical-revision",
      content: `# Context\n\n${text}`,
    };
    const output = renderPlanDocument(plan)
      .render(200)
      .map((line) => stripVTControlCharacters(line))
      .join("\n");
    expect({
      path: output.includes(`/plans/${visible}.md`),
      body: output.includes(visible),
      canonical: plan,
    }).toStrictEqual({
      path: true,
      body: true,
      canonical: {
        path: `/plans/${text}.md`,
        revision: "canonical-revision",
        content: `# Context\n\n${text}`,
      },
    });
  },
);

it("recognises current display metadata when native rendering omits structured content", () => {
  const output = renderPlanReview(
    {
      content: [],
      details: {
        formatVersion: 1,
        decision: "current",
        presentedPlan: {
          path: "/plans/review.md",
          revision: "technical-revision",
          content: "# Current plan\n",
        },
      },
    },
    { expanded: true, isPartial: false },
  )
    .render(100)
    .join("\n");
  expect({
    body: output.includes("Current plan"),
    legacy: output.includes("Legacy review metadata"),
    hash: output.includes("technical-revision"),
  }).toStrictEqual({ body: true, legacy: false, hash: false });
});

it("labels unrecognised historical results as safe legacy content", () => {
  const result = {
    content: [{ type: "text", text: "Old review \u001B[8mhidden\u001B[0m" }],
    details: { olderFormat: "stored metadata" },
  } satisfies Parameters<typeof renderPlanReview>[0];
  const output = renderPlanReview(result)
    .render(120)
    .map((line) => stripVTControlCharacters(line))
    .join("\n");
  expect({
    legacy: output.includes("Legacy/raw plan review"),
    visible: output.includes("\\u001b[8mhidden\\u001b[0m"),
  }).toStrictEqual({ legacy: true, visible: true });
});

it.each([
  { isPartial: true, edited: false },
  { isPartial: false, edited: false },
  { isPartial: false, edited: true },
])(
  "renders the plan once in collapsed native output (partial:$isPartial, edited:$edited)",
  ({ isPartial, edited }) => {
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
        content: [
          { type: "text", text: "Review finished." },
          ...(edited ? [{ type: "text" as const, text: plan.content }] : []),
        ],
        details: {
          decision: isPartial ? "pending" : "current",
          presentedPlan: plan,
          ...(edited ? { reviewSummary: "Review finished." } : {}),
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
      beginning: output.split("Paragraph 0").length - 1,
      ending: output.includes("Paragraph 44"),
      revision: output.includes("reviewed"),
      pendingFooter: output.includes("Awaiting approval"),
      finalSummary: output.includes("Review finished."),
    }).toStrictEqual({
      beginning: 1,
      ending: true,
      revision: false,
      pendingFooter: false,
      finalSummary: false,
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
      input: vi.fn<ReviewContext["ui"]["input"]>(),
      getToolsExpanded: () => false,
      setToolsExpanded: () => {},
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
  const edit = vi.fn<(path: string) => Promise<void>>(async () => {});
  const startTui = tui.start.bind(tui);
  const restarted = Promise.withResolvers<void>();
  const start = vi.spyOn(tui, "start").mockImplementation(() => {
    startTui();
    if (start.mock.calls.length === 2) {
      restarted.resolve();
    }
  });
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
    { name: "nvim", open: edit },
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

    terminal.send("\t");
    tui.renderNow();
    const cursorRow = question
      .render(terminal.columns)
      .findIndex((line) => line.includes(CURSOR_MARKER));
    expect(cursorRow).toBeGreaterThan(0);
    const inputRow = transcript.viewportHeight + cursorRow + 1;
    terminal.send(`\u001B[<0;3;${inputRow}M`);
    terminal.send(`\u001B[<0;3;${inputRow}m`);
    terminal.send("Keep interfaces.");
    terminal.send("\u0007");
    await restarted.promise;
    expect({ edits: edit.mock.calls, starts: start.mock.calls }).toStrictEqual({
      edits: [[plan.path]],
      starts: [[], []],
    });
    for (const key of ["\u001B", "\u001B[A", "\u001B[A", "\r"]) {
      terminal.send(key);
    }
    tui.renderNow();
    expect(await pending).toStrictEqual({
      decision: "current",
      presentedPlan: plan,
      feedback: "Keep interfaces.",
    });
  } finally {
    abort.abort();
    question.dispose();
    tui.stop();
    await pending;
  }
});
