import type {
  EntryRenderOptions,
  Theme,
} from "@earendil-works/pi-coding-agent";
import { Container, Image, Text, type Component } from "@earendil-works/pi-tui";
import { Type, type Static } from "typebox";
import { Check } from "typebox/value";
import { submitPlanOutputSchema, type SubmitPlanOutput } from "./contracts.ts";
import {
  displayPath,
  displayStoredMetadata,
  displayText,
} from "./presentation.ts";

export const outcomeEntryType = "dotfiles:planning-outcome:v1";

const imageSchema = Type.Object(
  {
    type: Type.Literal("image"),
    mimeType: Type.String({ pattern: "^image/(png|jpeg|gif|webp)$" }),
    data: Type.String({
      minLength: 1,
      pattern:
        "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$",
    }),
  },
  { additionalProperties: false },
);

export const outcomeSchema = Type.Union([
  Type.Object(
    {
      version: Type.Literal(1),
      event: Type.Literal("review"),
      decision: submitPlanOutputSchema.properties.decision,
      path: Type.String(),
      revision: Type.String(),
      feedback: Type.Optional(Type.String()),
      images: Type.Optional(Type.Array(imageSchema)),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      version: Type.Literal(1),
      event: Type.Literal("implementation-failed"),
      path: Type.String(),
      revision: Type.String(),
      reason: Type.String(),
    },
    { additionalProperties: false },
  ),
]);

export type PlanningOutcome = Static<typeof outcomeSchema>;

const reviewTitles: Record<SubmitPlanOutput["decision"], string> = {
  current: "User approved Pi's plan",
  clear: "User approved Pi's plan",
  revise: "User requested plan revisions",
  cancel: "Plan review cancelled",
};

export function renderPlanningOutcome(
  value: unknown,
  options: EntryRenderOptions,
  theme: Pick<Theme, "fg">,
): Component {
  const result = new Container();
  if (!Check(outcomeSchema, value)) {
    result.addChild(
      new Text(
        "Legacy planning outcome. Expand to inspect stored metadata.",
        1,
        0,
      ),
    );
    if (options.expanded) {
      result.addChild(new Text(displayStoredMetadata(value), 1, 0));
    }
    return result;
  }
  const title =
    value.event === "review"
      ? reviewTitles[value.decision]
      : "Implementation failed";
  result.addChild(
    new Text(
      theme.fg(value.event === "review" ? "accent" : "error", title),
      1,
      0,
    ),
  );
  if (value.event === "implementation-failed") {
    result.addChild(new Text(displayText(value.reason), 1, 0));
    return result;
  }
  if (value.decision === "current" || value.decision === "clear") {
    result.addChild(
      new Text(
        `Context action: ${value.decision === "current" ? "keep" : "clear"}`,
        1,
        0,
      ),
    );
  }
  if (value.feedback !== undefined) {
    result.addChild(
      new Text(`User feedback:\n${displayText(value.feedback)}`, 1, 0),
    );
  }
  for (const image of value.images ?? []) {
    result.addChild(
      new Image(
        image.data,
        image.mimeType,
        { fallbackColor: (text) => theme.fg("dim", text) },
        { maxHeightCells: 5 },
      ),
    );
  }
  if (options.expanded) {
    result.addChild(new Text(`Plan: ${displayPath(value.path)}`, 1, 0));
  }
  return result;
}
