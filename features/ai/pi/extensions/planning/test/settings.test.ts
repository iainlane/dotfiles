import { expect, it } from "vitest";
import { parsePlanningSettings } from "../src/settings.ts";

it("accepts configured tool identifiers and future settings", () => {
  expect(
    parsePlanningSettings({ readOnlyTools: ["inspect"], future: true }),
  ).toStrictEqual({ readOnlyTools: ["inspect"], future: true });
});
it.each([
  null,
  [],
  {},
  { readOnlyTools: "inspect" },
  { readOnlyTools: [1] },
  { readOnlyTools: [], researchExtensions: "extension.ts" },
  { readOnlyTools: [], mcpDirectTools: [1] },
])("rejects malformed planning settings: %j", (value) => {
  expect(() => parsePlanningSettings(value)).toThrow(
    "readOnlyTools array of tool identifiers",
  );
});
