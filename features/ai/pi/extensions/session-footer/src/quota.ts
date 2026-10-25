import { duration, finite, record, text } from "./text.ts";

export type Freshness = "fresh" | "cached" | "stale" | "unavailable";

export interface QuotaWindow {
  label: string;
  used: number | undefined;
  resetAt: number | undefined;
  windowSeconds: number | undefined;
}

export interface QuotaState {
  provider: string;
  windows: QuotaWindow[];
  lastSuccessAt: number | undefined;
  error: string | undefined;
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

function readWindow(raw: unknown): QuotaWindow | undefined {
  if (!record(raw)) {
    return undefined;
  }

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

  if (reading.error !== undefined && reading.error !== "") {
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

  return { ...previous, error: "INVALID_UPDATE" };
}

export function readQuota(
  raw: unknown,
  previous?: QuotaState,
): QuotaState | undefined {
  if (!record(raw) || !record(raw.state)) {
    return invalidUpdate(previous);
  }

  const state = raw.state;

  if (
    state.usage === undefined &&
    (state.provider === undefined || typeof state.provider === "string")
  ) {
    return undefined;
  }

  if (!record(state.usage) || typeof state.provider !== "string") {
    return invalidUpdate(previous, state.provider);
  }

  const usage = state.usage;
  const error = record(usage.error)
    ? text(usage.error.code) || "UNKNOWN"
    : undefined;

  if (
    error !== undefined &&
    error !== "" &&
    previous?.provider === state.provider
  ) {
    return { ...previous, error };
  }

  if (!Array.isArray(usage.windows) && (error === undefined || error === "")) {
    return invalidUpdate(previous, state.provider);
  }

  const windows: QuotaWindow[] = [];

  if (Array.isArray(usage.windows)) {
    for (const entry of usage.windows) {
      const window = readWindow(entry);

      if (!window) {
        return invalidUpdate(previous, state.provider);
      }

      windows.push(window);
    }
  }

  return {
    provider: state.provider,
    windows,
    lastSuccessAt: finite(usage.lastSuccessAt),
    error,
    account: text(usage.accountId, 96) || undefined,
    source: text(usage.credentialSource, 48) || undefined,
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
