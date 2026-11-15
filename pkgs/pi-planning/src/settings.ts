import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { Check } from "typebox/value";

const settingsSchema = Type.Object({
  researchExtensions: Type.Optional(Type.Array(Type.String())),
});
export type PlanningSettings = Static<typeof settingsSchema>;

export class PlanningSettingsError extends Error {
  override readonly name = "PlanningSettingsError";
  readonly path: string;

  constructor(path: string, cause: unknown) {
    super(`Cannot read planning settings at ${path}.`, { cause });
    this.path = path;
  }
}

export class PlanningSettingsFormatError extends Error {
  override readonly name = "PlanningSettingsFormatError";

  constructor() {
    super(
      "planning.json must be an object with an optional researchExtensions array of extension paths.",
    );
  }
}

export function readPlanningSettings(): PlanningSettings {
  const path = join(getAgentDir(), "planning.json");
  if (!existsSync(path)) {
    return {};
  }
  try {
    const value: unknown = JSON.parse(readFileSync(path, "utf8"));
    return parsePlanningSettings(value);
  } catch (error) {
    throw new PlanningSettingsError(path, error);
  }
}

function parsePlanningSettings(value: unknown): PlanningSettings {
  if (!Check(settingsSchema, value)) {
    throw new PlanningSettingsFormatError();
  }
  return value;
}
