import {
  getMarkdownTheme,
  type AgentToolResult,
} from "@earendil-works/pi-coding-agent";
import {
  Container,
  Markdown,
  Text,
  type Component,
} from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { Check } from "typebox/value";

const detailsSchema = Type.Object({
  presentedPlan: Type.Object({
    path: Type.String(),
    revision: Type.String(),
    content: Type.String(),
  }),
  decision: Type.String(),
});

export function renderPlanReview(
  result: Pick<AgentToolResult<unknown>, "content" | "details">,
): Component {
  const summary = result.content
    .flatMap((entry) => (entry.type === "text" ? [entry.text] : []))
    .join("\n");
  if (!Check(detailsSchema, result.details)) {
    return new Text(summary, 1, 0);
  }
  const { presentedPlan, decision } = result.details;
  const document = new Container();
  document.addChild(
    new Text(
      `Plan: ${presentedPlan.path}\nRevision: ${presentedPlan.revision}`,
      1,
      0,
    ),
  );
  document.addChild(
    new Markdown(presentedPlan.content, 1, 0, getMarkdownTheme()),
  );
  document.addChild(
    new Text(decision === "pending" ? "Awaiting approval" : summary, 1, 0),
  );
  return document;
}
