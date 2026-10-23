import {
  stripTerminalSequences,
  truncateToWidth,
} from "@earendil-works/pi-tui";

export function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function finite(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value
    : undefined;
}

export function text(value: unknown, width = 160): string {
  if (typeof value !== "string") return "";

  return truncateToWidth(
    stripTerminalSequences(value.slice(0, 4096))
      .replace(/[\p{Cc}\p{Cf}]/gu, " ")
      .replace(/\s+/g, " ")
      .trim(),
    width,
    "…",
  );
}

export function duration(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60_000));

  if (minutes < 60) return `${minutes}m`;

  const hours = Math.floor(minutes / 60);

  if (hours < 24)
    return `${hours}h${minutes % 60 || ""}${minutes % 60 ? "m" : ""}`;

  return `${Math.floor(hours / 24)}d${hours % 24 || ""}${hours % 24 ? "h" : ""}`;
}

export function tokens(value: number): string {
  if (value >= 1_000_000) return `${+(value / 1_000_000).toFixed(1)}M`;

  if (value >= 1000) return `${+(value / 1000).toFixed(1)}k`;

  return String(Math.round(value));
}

export function link(label: string, url: unknown): string {
  if (typeof url !== "string" || /[\p{Cc}\p{Cf}]/u.test(url)) return label;

  try {
    const parsed = new URL(url);

    if (
      !["http:", "https:"].includes(parsed.protocol) ||
      parsed.username ||
      parsed.password
    )
      return label;

    return `\u001b]8;;${parsed.href}\u001b\\${label}\u001b]8;;\u001b\\`;
  } catch {
    return label;
  }
}
