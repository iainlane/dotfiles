import { maxPlanCodeUnits } from "../../src/validation.ts";

export function boundaryText(prefix: string, character: string): string {
  const available = maxPlanCodeUnits - prefix.length;
  return (
    prefix + character.repeat(Math.floor(available / character.length))
  ).padEnd(maxPlanCodeUnits, "x");
}
