import { Type, type Static } from "typebox";
import { Check } from "typebox/value";

const settingsSchema = Type.Object({
  readOnlyTools: Type.Array(Type.String()),
});
type PlanningSettings = Static<typeof settingsSchema>;

export function parsePlanningSettings(value: unknown): PlanningSettings {
  if (!Check(settingsSchema, value)) {
    throw new Error(
      "planning.json must contain a readOnlyTools array of tool identifiers.",
    );
  }
  return value;
}
