import { Check } from "typebox/value";
import type { AccountWindowsResult } from "./catalogue.ts";
import { catalogueSchema, modelWindowSchema } from "./schemas.ts";

export const openaiProvider = "openai";
export const openaiBaseUrl = "https://api.openai.com/v1";

export function readContextWindows(
  data: unknown,
): ReadonlyMap<string, number> | undefined {
  if (!Check(catalogueSchema, data)) {
    return undefined;
  }

  const windows = new Map<string, number>();
  for (const row of data.models) {
    if (Check(modelWindowSchema, row)) {
      windows.set(row.slug, row.context_window);
    }
  }
  return windows.size > 0 ? windows : undefined;
}

export async function readAccountWindows(
  token: string,
  signal: AbortSignal,
): Promise<AccountWindowsResult> {
  try {
    const response = await fetch(`${openaiBaseUrl}/models`, {
      headers: { Authorization: `Bearer ${token}` },
      redirect: "error",
      signal,
    });
    if (!response.ok) {
      await response.body?.cancel();
      return { error: `OpenAI returned HTTP ${response.status}.` };
    }
    const data: unknown = await response.json();
    const windows = readContextWindows(data);
    return windows === undefined
      ? { error: "The account catalogue did not include any context windows." }
      : { windows };
  } catch {
    return {
      error: signal.aborted
        ? "The account catalogue request timed out or was cancelled."
        : "The account catalogue request or response could not be read.",
    };
  }
}
