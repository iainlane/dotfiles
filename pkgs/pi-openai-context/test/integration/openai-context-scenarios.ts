import assert from "node:assert/strict";

export type CatalogueResponse =
  | "failure"
  | "malformed"
  | "timeout"
  | "redirect"
  | "delayed"
  | "empty"
  | "small";

interface Scenario {
  catalogue?: CatalogueResponse;
  cachedWindow?: { tokens: number; stale?: true };
  expectedWindow?: number;
  offline?: true;
}

const scenarios = {
  oauth: { expectedWindow: 510_000 },
  renewed: { expectedWindow: 510_000 },
  "api-key": {},
  offline: { offline: true },
  cached: {
    offline: true,
    cachedWindow: { tokens: 530_000 },
    expectedWindow: 530_000,
  },
  failure: { catalogue: "failure" },
  malformed: { catalogue: "malformed" },
  timeout: { catalogue: "timeout" },
  override: {},
  overlap: { catalogue: "delayed", expectedWindow: 510_000 },
  "empty-retains-cache": {
    catalogue: "empty",
    cachedWindow: { tokens: 530_000, stale: true },
    expectedWindow: 530_000,
  },
  small: { catalogue: "small" },
  redirect: { catalogue: "redirect" },
} satisfies Record<string, Scenario>;

export const scenarioNames = Object.keys(scenarios);

function isMode(value: unknown): value is keyof typeof scenarios {
  return typeof value === "string" && Object.hasOwn(scenarios, value);
}

export function readScenario(mode: unknown): Scenario {
  assert.ok(isMode(mode), `Unknown OpenAI context probe mode: ${String(mode)}`);
  return scenarios[mode];
}
