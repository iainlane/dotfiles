import { expect, it } from "vitest";
import { parsePlanningSettings } from "#planning/settings.ts";

it.each([{}, { researchExtensions: ["extension.ts"], future: true }])(
  "accepts native research extension settings: %j",
  (settings) => {
    expect(parsePlanningSettings(settings)).toStrictEqual(settings);
  },
);

it.each([
  null,
  [],
  { researchExtensions: "extension.ts" },
  { researchExtensions: [1] },
])("rejects malformed planning settings: %j", (value) => {
  expect(() => parsePlanningSettings(value)).toThrow(
    "researchExtensions array of extension paths",
  );
});
