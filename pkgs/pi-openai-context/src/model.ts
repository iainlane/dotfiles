import type { Api, Model } from "@earendil-works/pi-ai";
import { readFile } from "node:fs/promises";
import { Check } from "typebox/value";
import { modelConfigSchema } from "./schemas.ts";

export interface ContextLimits {
  contextWindow: number;
  maxTokens?: number;
}

export type ContextPolicy =
  | { kind: "override"; limits: ContextLimits }
  | { kind: "automatic" | "configured" | "unavailable" };

export async function readContextPolicy(
  path: string,
  id: string,
): Promise<ContextPolicy> {
  try {
    const content = await readFile(path, "utf8");
    // Match Pi's private JSON parser so a valid override cannot be missed.
    const json = content
      .replace(/^\uFEFF/, "")
      .replaceAll(/"(?:\\.|[^"\\])*"|\/\/[^\n]*/g, (token) =>
        token.startsWith('"') ? token : "",
      )
      .replaceAll(/"(?:\\.|[^"\\])*"|,(?=\s*[}\]])/g, (token) =>
        token.startsWith('"') ? token : "",
      );
    const settings: unknown = JSON.parse(json);
    if (!Check(modelConfigSchema, settings)) {
      return { kind: "unavailable" };
    }
    const provider = settings.providers.openai;
    if (provider?.models?.some((model) => model.id === id) === true) {
      return { kind: "configured" };
    }
    const override = provider?.modelOverrides?.[id];
    if (override?.contextWindow === undefined) {
      return { kind: "automatic" };
    }
    return {
      kind: "override",
      limits: { ...override, contextWindow: override.contextWindow },
    };
  } catch (error) {
    return error instanceof Error && "code" in error && error.code === "ENOENT"
      ? { kind: "automatic" }
      : { kind: "unavailable" };
  }
}

const contextAdjustment = Symbol.for(
  "@dotfiles/pi-openai-context/context-adjustment",
);
type AdjustmentSource = "account" | "override";
type ContextModel = Model<Api> & {
  [contextAdjustment]?: {
    source: AdjustmentSource;
    original: Required<ContextLimits>;
  };
};

export function restoreContext(
  model: ContextModel,
  source?: AdjustmentSource,
): ContextModel {
  const adjustment = model[contextAdjustment];
  if (
    adjustment === undefined ||
    (source !== undefined && adjustment.source !== source)
  ) {
    return model;
  }
  return { ...model, ...adjustment.original };
}

export function adjustContext(
  model: ContextModel,
  limits: ContextLimits,
  source: AdjustmentSource,
): ContextModel | undefined {
  const previous = model[contextAdjustment];
  const original = previous?.original ?? {
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
  };
  const { contextWindow, maxTokens = original.maxTokens } = limits;
  if (contextWindow <= maxTokens) {
    return undefined;
  }
  if (
    contextWindow === original.contextWindow &&
    maxTokens === original.maxTokens
  ) {
    return restoreContext(model);
  }
  if (
    previous?.source === source &&
    contextWindow === model.contextWindow &&
    maxTokens === model.maxTokens
  ) {
    return model;
  }

  // Pi keeps the active model when it reloads extensions.
  return Object.defineProperty(
    { ...model, contextWindow, maxTokens },
    contextAdjustment,
    { value: { source, original } },
  );
}
