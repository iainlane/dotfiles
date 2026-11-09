import {
  detailRow,
  paragraphs,
  sectionsRow,
  type InspectionContent,
  type InspectionNavigation,
} from "./inspection-page.ts";
import type { FooterSnapshot, UsageTotals } from "#footer/domain/state.ts";
import { duration, text, tokens } from "#footer/shared/text.ts";

function cost(value: UsageTotals): string {
  return `${value.costFromProvider ? "" : "≈"}$${value.cost.toFixed(2)}`;
}
function accounting(value: UsageTotals): string[] {
  const prompt = value.input + value.cacheRead + value.cacheWrite;
  return [
    `${value.costFromProvider ? "Billed total reported by the provider" : "Recorded estimate"}: $${value.cost.toFixed(4)}`,
    `Input: ${value.input.toLocaleString("en-GB")} tokens`,
    `Output: ${value.output.toLocaleString("en-GB")} tokens`,
    `Cache read: ${value.cacheRead.toLocaleString("en-GB")} tokens`,
    `Cache write: ${value.cacheWrite.toLocaleString("en-GB")} tokens`,
    `Prompt tokens: ${prompt.toLocaleString("en-GB")}`,
  ];
}
function sessionAccounting(state: FooterSnapshot): string[] {
  const usage = state.usage;
  const prompt = usage.input + usage.cacheRead + usage.cacheWrite;
  return [
    ...accounting(usage),
    `Whole-session cache hit rate: ${prompt > 0 ? `${((usage.cacheRead / prompt) * 100).toFixed(1)}%` : "Unavailable"}`,
    "Session totals include all recorded branches, tool usage, summaries and cache warming. Auxiliary and delegation reports are separate.",
    "Cache hit rate uses the last active-branch prompt. Its denominator includes input, cache read and cache write tokens.",
    "The whole-session cache rate has a different denominator and does not estimate invoice savings.",
    ...(usage.costFromProvider
      ? []
      : ["Recorded estimates are not verified invoices."]),
  ];
}
export function usageContent(
  state: FooterSnapshot,
  navigation: InspectionNavigation,
): InspectionContent {
  const usage = state.usage;
  const hit =
    usage.latestHit === undefined
      ? "Unavailable"
      : `${usage.latestHit.toFixed(1)}%`;
  const summary = paragraphs(
    `Session cost: ${cost(usage)}`,
    `Cache hit rate: ${hit}`,
    `Tokens: ${tokens(usage.input)} input · ${tokens(usage.cacheRead)} cached · ${tokens(usage.output)} output`,
    `Session age: ${duration(state.now - state.startedAt)}`,
  );
  const auxiliary = state.auxiliaryUsage;
  if (
    auxiliary.cost > 0 ||
    auxiliary.input +
      auxiliary.output +
      auxiliary.cacheRead +
      auxiliary.cacheWrite >
      0
  ) {
    summary.push({ value: `Auxiliary cost: ${cost(auxiliary)}` });
  }
  if (state.rpcErrors.cost !== undefined) {
    summary.push({
      value: text(state.rpcErrors.cost.message),
      colour: "error",
    });
  }
  return {
    summary,
    rows: [
      detailRow(navigation, "Usage", "accounting", "Cost & token details", () =>
        sessionAccounting(state),
      ),
      detailRow(navigation, "Usage", "timing", "Timing", () => [
        `Session age: ${duration(state.now - state.startedAt)}`,
        `Current run: ${state.activity.runningSince === undefined ? "Not running" : duration(state.now - state.activity.runningSince)}`,
        `Observed active-work time: ${duration(state.activity.activeMs + (state.activity.activeSince === undefined ? 0 : state.now - state.activity.activeSince))}`,
        `Observed since: ${new Date(state.activity.observedSince).toISOString()}`,
        `Compaction: ${state.activity.compactingSince === undefined ? "Not compacting" : duration(state.now - state.activity.compactingSince)}`,
        `Current tool: ${state.activity.tool ?? "None"}`,
      ]),
      detailRow(navigation, "Usage", "auxiliary", "Auxiliary usage", () =>
        accounting(state.auxiliaryUsage),
      ),
      {
        key: "delegation",
        value: "Delegation",
        run: () =>
          navigation.open({
            kind: "menu",
            title: "Usage › Delegation",
            content: () => ({
              summary: paragraphs(
                state.delegationCost === undefined
                  ? "No delegation report yet."
                  : "Delegation accounting is separate from session cost.",
                ...(state.rpcErrors.cost === undefined
                  ? []
                  : [text(state.rpcErrors.cost.message)]),
              ),
              rows: [
                detailRow(
                  navigation,
                  "Usage › Delegation",
                  "raw",
                  "Raw report",
                  () => [
                    "Safe JSON · at most 2,000 columns and 4,096 source characters; an ellipsis marks truncation.",
                    state.delegationCost === undefined
                      ? "No delegation report yet."
                      : text(JSON.stringify(state.delegationCost), 2000),
                  ],
                ),
              ],
            }),
          }),
      },
      sectionsRow(navigation),
    ],
  };
}
