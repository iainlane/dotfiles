import { Type, type Static } from "typebox";
import { Check } from "typebox/value";
import {
  duration,
  finite,
  record,
  text,
  timestamp,
} from "#footer/shared/text.ts";

export type Freshness = "fresh" | "cached" | "stale" | "unavailable";

export interface QuotaWindow {
  label: string;
  used: number | undefined;
  resetAt: number | undefined;
  windowSeconds: number | undefined;
}

interface QuotaError {
  code: string;
  httpStatus?: number;
  credential?: { source: string; expired: boolean };
}

export interface QuotaState {
  provider: string;
  windows: QuotaWindow[];
  lastSuccessAt: number | undefined;
  error: QuotaError | undefined;
  skippedExpiredCredential?: "pi";
  account: string | undefined;
  source: string | undefined;
}

export interface QuotaView {
  label: string;
  used: number | undefined;
  reset: string | undefined;
  pace: number | undefined;
  freshness: Freshness;
}

const stateSchema = Type.Object({
  state: Type.Record(Type.String(), Type.Unknown()),
});
const emptyStateSchema = Type.Object({
  state: Type.Object({
    provider: Type.Optional(Type.String()),
    usage: Type.Optional(Type.Undefined()),
  }),
});
const usageSchema = Type.Object({
  state: Type.Object({
    provider: Type.String(),
    usage: Type.Object({
      error: Type.Optional(Type.Unknown()),
      windows: Type.Optional(Type.Unknown()),
      lastSuccessAt: Type.Optional(Type.Unknown()),
      accountId: Type.Optional(Type.Unknown()),
      credentialSource: Type.Optional(Type.Unknown()),
      skippedExpiredCredential: Type.Optional(Type.Unknown()),
    }),
  }),
});
const windowSchema = Type.Object({
  label: Type.String(),
  usedPercent: Type.Optional(Type.Unknown()),
  resetAt: Type.Optional(Type.Unknown()),
  windowSeconds: Type.Optional(Type.Unknown()),
});
const windowsSchema = Type.Array(windowSchema);

function readWindow(raw: Static<typeof windowSchema>): QuotaWindow | undefined {
  const label = text(raw.label, 48);

  if (!label) {
    return undefined;
  }

  const used = finite(raw.usedPercent);
  const seconds = finite(raw.windowSeconds);
  const resetAt =
    typeof raw.resetAt === "string" ? Date.parse(raw.resetAt) : NaN;

  return {
    label,
    used: used !== undefined && used <= 100 ? used : undefined,
    resetAt: Number.isFinite(resetAt) ? resetAt : undefined,
    windowSeconds:
      seconds !== undefined && seconds !== 0 && seconds > 0
        ? seconds
        : undefined,
  };
}

function freshness(
  reading: QuotaState,
  window: QuotaWindow,
  now: number,
): Freshness {
  if (reading.lastSuccessAt === undefined || window.used === undefined) {
    return "unavailable";
  }

  const age = now - reading.lastSuccessAt;

  if (
    age < 0 ||
    age > 300_000 ||
    (window.resetAt !== undefined && now >= window.resetAt)
  ) {
    return "unavailable";
  }

  if (age > 30_000) {
    return "stale";
  }

  if (reading.error !== undefined) {
    return "cached";
  }

  return "fresh";
}

function invalidUpdate(
  previous: QuotaState | undefined,
  provider?: unknown,
): QuotaState | undefined {
  if (
    !previous ||
    (typeof provider === "string" && provider !== previous.provider)
  ) {
    return undefined;
  }

  return { ...previous, error: { code: "INVALID_UPDATE" } };
}

function readError(raw: unknown): QuotaError | undefined {
  if (!record(raw)) {
    return undefined;
  }

  const error: QuotaError = { code: text(raw.code, 48) || "UNKNOWN" };
  if (
    typeof raw.httpStatus === "number" &&
    Number.isInteger(raw.httpStatus) &&
    raw.httpStatus >= 100 &&
    raw.httpStatus <= 599
  ) {
    error.httpStatus = raw.httpStatus;
  }

  if (record(raw.credential)) {
    const source = text(raw.credential.source, 48);
    if (source !== "") {
      error.credential = { source, expired: raw.credential.expired === true };
    }
  }

  return error;
}

export function quotaErrorDescription(error: QuotaError): string {
  const details = [error.code];
  if (error.httpStatus !== undefined) {
    details.push(`HTTP ${error.httpStatus}`);
  }
  return error.credential?.expired === true
    ? `Credential expired (${details.join(", ")})`
    : details.join(" · ");
}

export function quotaDiagnosticLines(
  reading: QuotaState | undefined,
): string[] {
  const error = reading?.error;
  const lines = [
    `Last error: ${error === undefined ? "none reported" : quotaErrorDescription(error)}`,
  ];
  if (error?.credential !== undefined) {
    lines.push(`Failed credential source: ${error.credential.source}`);
  }
  if (reading?.skippedExpiredCredential === "pi") {
    lines.push("Skipped expired Pi Codex credential");
  }
  return lines;
}

export function readQuota(
  raw: unknown,
  previous?: QuotaState,
): QuotaState | undefined {
  if (!Check(stateSchema, raw)) {
    return invalidUpdate(previous);
  }

  const state = raw.state;

  if (Check(emptyStateSchema, raw)) {
    return undefined;
  }
  if (!Check(usageSchema, raw)) {
    return invalidUpdate(previous, state.provider);
  }

  const usage = raw.state.usage;
  const error = readError(usage.error);

  if (
    error !== undefined &&
    previous !== undefined &&
    previous.provider === raw.state.provider
  ) {
    return { ...previous, error };
  }

  if (!Check(windowsSchema, usage.windows) && error === undefined) {
    return invalidUpdate(previous, raw.state.provider);
  }

  const windows: QuotaWindow[] = [];

  if (Check(windowsSchema, usage.windows)) {
    for (const entry of usage.windows) {
      const window = readWindow(entry);

      if (!window) {
        return invalidUpdate(previous, raw.state.provider);
      }

      windows.push(window);
    }
  }

  return {
    provider: raw.state.provider,
    windows,
    lastSuccessAt: timestamp(usage.lastSuccessAt),
    error,
    account: text(usage.accountId, 96) || undefined,
    source: text(usage.credentialSource, 48) || undefined,
    ...(usage.skippedExpiredCredential === "pi"
      ? { skippedExpiredCredential: "pi" }
      : {}),
  };
}

export function quotaWindows(
  reading: QuotaState | undefined,
  now: number,
): QuotaView[] {
  if (!reading) {
    return [];
  }

  return reading.windows.map((window) => {
    const status = freshness(reading, window, now);
    const used = status === "unavailable" ? undefined : window.used;
    const reset =
      used !== undefined && window.resetAt !== undefined
        ? duration(window.resetAt - now)
        : undefined;
    const elapsed =
      window.windowSeconds !== undefined &&
      window.windowSeconds !== 0 &&
      window.resetAt !== undefined
        ? Math.max(
            0,
            Math.min(
              1,
              1 - (window.resetAt - now) / (window.windowSeconds * 1000),
            ),
          )
        : undefined;

    return {
      label: window.label,
      used,
      reset,
      pace:
        used !== undefined && elapsed !== undefined
          ? Math.round(used - elapsed * 100)
          : undefined,
      freshness: status,
    };
  });
}
