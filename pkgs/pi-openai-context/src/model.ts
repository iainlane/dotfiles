import type { Api, Model } from "@earendil-works/pi-ai";
import { readFile } from "node:fs/promises";
import type { Static } from "typebox";
import { Check } from "typebox/value";
import { openaiBaseUrl, openaiProvider } from "./catalogue-client.ts";
import { modelConfigSchema } from "./schemas.ts";

export interface ContextLimits {
  contextWindow: number;
  maxTokens?: number;
}

export type ContextPolicy =
  | { kind: "override"; limits: ContextLimits }
  | { kind: "automatic" | "configured" | "unavailable" };

export function isOpenAIResponsesModel(
  model: Model<Api> | undefined,
): model is Model<"openai-responses"> {
  return (
    model?.provider === openaiProvider &&
    model.api === "openai-responses" &&
    model.baseUrl === openaiBaseUrl
  );
}

type ModelConfigRead =
  | {
      kind: "available";
      content: string | undefined;
      openai?: Static<typeof modelConfigSchema>["providers"]["openai"];
    }
  | { kind: "unavailable" };

export async function readModelConfig(path: string): Promise<ModelConfigRead> {
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
    return { kind: "available", content, openai: settings.providers.openai };
  } catch (error) {
    return error instanceof Error && "code" in error && error.code === "ENOENT"
      ? { kind: "available", content: undefined }
      : { kind: "unavailable" };
  }
}

export function contextPolicy(
  config: ModelConfigRead,
  id: string,
): ContextPolicy {
  if (config.kind === "unavailable") {
    return config;
  }
  if (config.openai?.models?.some((model) => model.id === id) === true) {
    return { kind: "configured" };
  }
  const override = config.openai?.modelOverrides?.[id];
  if (override?.contextWindow === undefined) {
    return { kind: "automatic" };
  }
  return {
    kind: "override",
    limits: { ...override, contextWindow: override.contextWindow },
  };
}

export async function readContextPolicy(
  path: string,
  id: string,
): Promise<ContextPolicy> {
  return contextPolicy(await readModelConfig(path), id);
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
  const restored = { ...model, ...adjustment.original };
  delete restored[contextAdjustment];
  return restored;
}

export function adjustContext(
  model: ContextModel,
  limits: ContextLimits,
  source: AdjustmentSource,
  scope: "session" | "registry" = "session",
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

  // Pi keeps the active model on reload and spreads registry models when applying models.json.
  return Object.defineProperty(
    { ...model, contextWindow, maxTokens },
    contextAdjustment,
    { value: { source, original }, enumerable: scope === "registry" },
  );
}
