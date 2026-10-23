import type { ThemeColor } from "@earendil-works/pi-coding-agent";
import type { GitState } from "./git.ts";
import type { QuotaView } from "./quota.ts";

export interface FooterStyle {
  readonly color: ThemeColor;
  readonly bold?: boolean;
}

export const styles = {
  model: { color: "accent", bold: true },
  provider: { color: "muted" },
  serviceTier: { color: "warning" },
  directory: { color: "mdCode", bold: true },
  measurement: { color: "toolTitle" },
  workflow: { color: "mdLink" },
  tool: { color: "toolTitle" },
  activity: { color: "accent" },
  pullRequest: { color: "accent" },
  label: { color: "muted" },
  text: { color: "text" },
  detail: { color: "dim" },
  separator: { color: "border" },
  success: { color: "success" },
  warning: { color: "warning" },
  error: { color: "error" },
} satisfies Record<string, FooterStyle>;

const thinkingColors = new Map<string, ThemeColor>([
  ["off", "thinkingOff"],
  ["minimal", "thinkingMinimal"],
  ["low", "thinkingLow"],
  ["medium", "thinkingMedium"],
  ["high", "thinkingHigh"],
  ["xhigh", "thinkingXhigh"],
  ["max", "thinkingMax"],
]);

export function thinkingStyle(level: string): FooterStyle {
  return { color: thinkingColors.get(level) ?? styles.label.color };
}

export function contextStyle(percent: number | null): FooterStyle {
  if (percent === null) return styles.detail;

  if (percent >= 90) return styles.error;

  if (percent >= 75) return styles.warning;

  return styles.measurement;
}

export function quotaStyle(freshness: QuotaView["freshness"]): FooterStyle {
  if (freshness === "unavailable") return styles.detail;

  if (freshness !== "fresh") return styles.warning;

  return styles.measurement;
}

export function gitStyle(git: GitState): FooterStyle {
  if (git.stale) return styles.detail;

  if (git.conflicts) return styles.error;

  if (git.staged || git.unstaged || git.untracked) return styles.warning;

  return styles.success;
}
