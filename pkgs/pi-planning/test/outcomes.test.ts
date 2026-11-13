import { stripVTControlCharacters } from "node:util";
import { expect, it } from "vitest";
import { renderPlanningOutcome } from "#planning/outcomes.ts";

const theme = { fg: (_colour: string, text: string) => text };
const options = { expanded: false };

it.each([
  {
    decision: "current",
    title: "User approved Pi's plan",
    context: "Context action: keep",
  },
  {
    decision: "clear",
    title: "User approved Pi's plan",
    context: "Context action: clear",
  },
  {
    decision: "revise",
    title: "User requested plan revisions",
    context: undefined,
  },
  { decision: "cancel", title: "Plan review cancelled", context: undefined },
])(
  "replays a distinct $decision outcome outside the plan body",
  ({ decision, title, context }) => {
    const output = renderPlanningOutcome(
      {
        version: 1,
        event: "review",
        decision,
        path: "/plans/document.md",
        revision: "technical-revision",
        feedback: "\u001B[8mFeedback\u001B[0m",
      },
      options,
      theme,
    )
      .render(100)
      .map((line) => stripVTControlCharacters(line).trim())
      .filter(Boolean);
    expect(output).toStrictEqual([
      title,
      ...(context === undefined ? [] : [context]),
      "User feedback:",
      "\\u001b[8mFeedback\\u001b[0m",
    ]);
  },
);

it("replays an escaped transition failure without an approval caption", () => {
  const output = renderPlanningOutcome(
    {
      version: 1,
      event: "implementation-failed",
      path: "/plans/document.md",
      revision: "technical-revision",
      reason: "Failed\u001B[8msecret",
    },
    options,
    theme,
  )
    .render(100)
    .map((line) => stripVTControlCharacters(line).trim())
    .filter(Boolean);
  expect(output).toStrictEqual([
    "Implementation failed",
    "Failed\\u001b[8msecret",
  ]);
});

it("does not infer approval from unrecognised legacy prose", () => {
  const legacy = { text: "User approved Pi's plan\u001B[8mconcealed" };
  const collapsed = renderPlanningOutcome(legacy, options, theme)
    .render(100)
    .join("\n");
  const expanded = renderPlanningOutcome(legacy, { expanded: true }, theme)
    .render(100)
    .join("\n");
  expect({
    caption: collapsed.includes("User approved Pi's plan"),
    legacy: collapsed.includes("Legacy planning outcome"),
    raw: expanded.includes("\\u001b[8mconcealed"),
    conceal: expanded.includes("\u001B[8m"),
  }).toStrictEqual({ caption: false, legacy: true, raw: true, conceal: false });
});

it("reports legacy data that cannot be serialised without failing the renderer", () => {
  const circular: { self?: unknown } = {};
  circular.self = circular;
  expect(
    renderPlanningOutcome(circular, { expanded: true }, theme)
      .render(100)
      .map((line) => stripVTControlCharacters(line).trim())
      .filter(Boolean),
  ).toStrictEqual([
    "Legacy planning outcome. Expand to inspect stored metadata.",
    "Raw metadata could not be serialised.",
  ]);
});
