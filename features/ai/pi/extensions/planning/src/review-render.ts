import {
  getMarkdownTheme,
  type AgentToolResult,
  type ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import {
  Container,
  Markdown,
  Text,
  type Component,
} from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { planRevisionSchema, submitPlanOutputSchema } from "./contracts.ts";
import {
  displayPath,
  displayStoredMetadata,
  displayText,
} from "./presentation.ts";
import { validateInlinePlanText } from "./validation.ts";

const detailsSchema = Type.Object({
  presentedPlan: planRevisionSchema,
  decision: Type.Union([
    Type.Literal("pending"),
    submitPlanOutputSchema.properties.decision,
  ]),
});

const currentFormatSchema = Type.Object({ formatVersion: Type.Literal(1) });

export function renderPlanReview(
  result: Pick<
    AgentToolResult<unknown>,
    "content" | "details" | "structuredContent"
  >,
  options?: ToolRenderResultOptions,
): Component {
  const expanded = options?.expanded === true;
  if (Check(submitPlanOutputSchema, result.structuredContent)) {
    return renderPlanDocument(result.structuredContent.plan);
  }
  if (Check(detailsSchema, result.details)) {
    const document = renderPlanDocument(result.details.presentedPlan);
    if (
      !expanded ||
      result.details.decision === "pending" ||
      Check(currentFormatSchema, result.details)
    ) {
      return document;
    }
    const legacy = new Container();
    legacy.addChild(document);
    legacy.addChild(new Text("Legacy review metadata:", 1, 0));
    legacy.addChild(new Text(displayStoredMetadata(result.details), 1, 0));
    return legacy;
  }
  const legacy = new Container();
  legacy.addChild(
    new Text(
      "Legacy/raw plan review. Expand to inspect stored metadata.",
      1,
      0,
    ),
  );
  const summary = result.content
    .flatMap((entry) => (entry.type === "text" ? [entry.text] : []))
    .join("\n");
  legacy.addChild(new Text(displayText(summary), 1, 0));
  if (expanded) {
    legacy.addChild(
      new Text(
        displayStoredMetadata({
          details: result.details,
          structuredContent: result.structuredContent,
        }),
        1,
        0,
      ),
    );
  }
  return legacy;
}

export function renderPlanDocument(value: unknown): Component {
  if (!Check(planRevisionSchema, value)) {
    return new Text("The saved plan cannot be displayed.", 1, 0);
  }
  try {
    validateInlinePlanText(value.content);
  } catch (error) {
    return new Text(displayText(String(error)), 1, 0);
  }
  const document = new Container();
  document.addChild(new Text("Here is Pi's plan:", 1, 0));
  document.addChild(new Text(`Plan: ${displayPath(value.path)}`, 1, 0));
  document.addChild(
    new Markdown(
      displayText(value.content),
      1,
      0,
      getMarkdownTheme(),
      undefined,
      { preserveBackslashEscapes: true, renderLatex: false },
    ),
  );
  return document;
}
