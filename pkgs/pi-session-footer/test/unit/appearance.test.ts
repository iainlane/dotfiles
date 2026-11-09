import { expect, it } from "vitest";
import {
  parseAppearance,
  parseSymbol,
  SettingsError,
} from "#footer/configuration/appearance.ts";

it.each([
  { value: "git", expected: "git" },
  { value: "", expected: "" },
  { value: { text: "[G]" }, expected: "[G]" },
  { value: { alias: "git" }, expected: { alias: "git" } },
  {
    value: { alias: "git", colour: "accent" },
    expected: { alias: "git", colour: "accent" },
  },
  {
    value: { text: "+", colour: "success" },
    expected: { text: "+", colour: "success" },
  },
  { value: { colour: "#12aBcD" }, expected: { colour: "#12aBcD" } },
  { value: {}, expected: undefined },
])("parses literal or styled symbol $value", ({ value, expected }) => {
  expect(parseSymbol(value, "symbol")).toStrictEqual(expected);
});

it.each([
  { value: { text: "x", alias: "git" }, field: "symbol" },
  { value: { alias: "not-an-alias" }, field: "symbol.alias" },
  { value: { text: "x", color: "accent" }, field: "symbol.color" },
  { value: { colour: "selectedBg" }, field: "symbol.colour" },
  { value: { colour: "red" }, field: "symbol.colour" },
  { value: { colour: "#fff" }, field: "symbol.colour" },
  { value: "", field: "symbol" },
  { value: "\u001B[31mx", field: "symbol" },
  { value: "界界界界界", field: "symbol" },
])("rejects invalid symbol $value at $field", ({ value, field }) => {
  let caught: unknown;
  try {
    parseSymbol(value, "symbol");
  } catch (error) {
    caught = error;
  }
  expect(caught).toBeInstanceOf(SettingsError);
  if (!(caught instanceof SettingsError)) {
    throw new TypeError("Expected a structured settings error");
  }
  expect(caught.field).toBe(field);
});

it.each([
  ["context", "gauge-used"],
  ["thinking", "off"],
] as const)("rejects text colours for symbol-only %s parts", (id, role) => {
  expect(() =>
    parseAppearance({ roles: { [role]: { colour: "text" } } }, "placement", id),
  ).toThrow(`placement.roles.${role}.colour`);
});

it("rejects multi-column symbols for repeating gauge parts", () => {
  expect(() =>
    parseAppearance(
      { roles: { "gauge-used": { symbol: "##" } } },
      "top-right[0]",
      "context",
    ),
  ).toThrow("top-right[0].roles.gauge-used.symbol");
});

it("keeps text and symbol colours independent, including role overrides", () => {
  expect(
    parseAppearance(
      {
        colour: "text",
        symbol: { colour: "accent" },
        roles: {
          staged: { colour: "text", symbol: { text: "+", colour: "success" } },
        },
      },
      "top-left[1]",
      "git",
    ),
  ).toStrictEqual({
    colour: "text",
    symbol: { colour: "accent" },
    roles: {
      staged: { colour: "text", symbol: { text: "+", colour: "success" } },
    },
  });
});

it.each([
  {
    value: { roles: { imaginary: { colour: "accent" } } },
    field: "top-left[1].roles.imaginary",
  },
  {
    value: { roles: { provider: { symbol: "x" } } },
    field: "top-left[1].roles.provider.symbol",
  },
  { value: { color: "accent" }, field: "top-left[1].color" },
])("rejects unsupported appearance $value", ({ value, field }) => {
  expect(() => parseAppearance(value, "top-left[1]", "model")).toThrow(field);
});
