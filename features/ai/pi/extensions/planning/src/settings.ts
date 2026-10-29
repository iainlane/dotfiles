import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { Check } from "typebox/value";

const settingsSchema = Type.Object({
  readOnlyTools: Type.Array(Type.String()),
  researchExtensions: Type.Optional(Type.Array(Type.String())),
  mcpDirectTools: Type.Optional(Type.Array(Type.String())),
});
export type PlanningSettings = Static<typeof settingsSchema>;

export function readPlanningSettings(): PlanningSettings {
  const path = join(getAgentDir(), "planning.json");
  if (!existsSync(path)) {
    return { readOnlyTools: [] };
  }
  try {
    const value: unknown = JSON.parse(readFileSync(path, "utf8"));
    return parsePlanningSettings(value);
  } catch (error) {
    throw new Error(`Cannot read planning settings at ${path}.`, {
      cause: error,
    });
  }
}

export function parsePlanningSettings(value: unknown): PlanningSettings {
  if (!Check(settingsSchema, value)) {
    throw new Error(
      "planning.json must contain a readOnlyTools array of tool identifiers.",
    );
  }
  return value;
}
