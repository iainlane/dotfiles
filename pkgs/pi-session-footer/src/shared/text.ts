import { Type } from "typebox";
import { Check } from "typebox/value";
import {
  stripTerminalSequences,
  sliceByColumn,
  visibleWidth,
} from "@earendil-works/pi-tui";

export const MAX_TIMESTAMP = 8.64e15;

const recordSchema = Type.Record(Type.String(), Type.Unknown());
const nonnegativeNumberSchema = Type.Number({ minimum: 0 });
const timestampSchema = Type.Number({ minimum: 0, maximum: MAX_TIMESTAMP });

export function record(value: unknown): value is Record<string, unknown> {
  return Check(recordSchema, value);
}

export function finite(value: unknown): number | undefined {
  return Check(nonnegativeNumberSchema, value) ? value : undefined;
}

export function timestamp(value: unknown): number | undefined {
  return Check(timestampSchema, value) ? value : undefined;
}

export function text(value: unknown, width = 160): string {
  if (typeof value !== "string") {
    return "";
  }

  const clean = stripTerminalSequences(value.slice(0, 4096))
    .replaceAll(/[\p{Cc}\p{Cf}]/gu, " ")
    .replaceAll(/\s+/g, " ")
    .trim();
  if (width <= 0) {
    return "";
  }
  if (visibleWidth(clean) <= width) {
    return clean;
  }
  return sliceByColumn(clean, 0, width - 1, true) + "…";
}

export function reportText(report: unknown, width: number): string {
  try {
    return text(JSON.stringify(report), width);
  } catch {
    return "unavailable: the report cannot be serialised as JSON";
  }
}

export function duration(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60_000));

  if (minutes < 60) {
    return `${minutes}m`;
  }

  const hours = Math.floor(minutes / 60);

  if (hours < 24) {
    return `${hours}h${minutes % 60 || ""}${minutes % 60 ? "m" : ""}`;
  }

  return `${Math.floor(hours / 24)}d${hours % 24 || ""}${hours % 24 ? "h" : ""}`;
}

export function tokens(value: number): string {
  if (value >= 1_000_000) {
    return `${+(value / 1_000_000).toFixed(1)}M`;
  }

  if (value >= 1000) {
    return `${+(value / 1000).toFixed(1)}k`;
  }

  return String(Math.round(value));
}

export function link(label: string, url: unknown): string {
  if (typeof url !== "string" || /[\p{Cc}\p{Cf}]/u.test(url)) {
    return label;
  }

  try {
    const parsed = new URL(url);

    if (
      !["http:", "https:"].includes(parsed.protocol) ||
      parsed.username ||
      parsed.password
    ) {
      return label;
    }

    return `\u001B]8;;${parsed.href}\u001B\\${label}\u001B]8;;\u001B\\`;
  } catch {
    return label;
  }
}
