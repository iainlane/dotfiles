import { expect, it } from "vitest";
import {
  parseAppearance,
  parseSymbol,
} from "#footer/configuration/appearance.ts";
import {
  InlineTextTooWideError,
  InvalidColourError,
  InvalidInlineTextError,
  MultiColumnSymbolError,
  SymbolNotAllowedError,
  SymbolTextAndAliasError,
  TextColourNotAllowedError,
  UnknownSettingError,
  UnknownSymbolAliasError,
  UnknownWidgetPartError,
} from "#footer/configuration/settings-errors.ts";
import { thrown } from "#test/support/thrown.ts";

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
  {
    value: { text: "x", alias: "git" },
    error: new SymbolTextAndAliasError("symbol"),
  },
  {
    value: { alias: "not-an-alias" },
    error: new UnknownSymbolAliasError("symbol.alias"),
  },
  {
    value: { text: "x", color: "accent" },
    error: new UnknownSettingError("symbol.color"),
  },
  {
    value: { colour: "selectedBg" },
    error: new InvalidColourError("symbol.colour"),
  },
  { value: { colour: "red" }, error: new InvalidColourError("symbol.colour") },
  { value: { colour: "#fff" }, error: new InvalidColourError("symbol.colour") },
  { value: "", error: new InvalidInlineTextError("symbol") },
  { value: "\u001B[31mx", error: new InvalidInlineTextError("symbol") },
  { value: "界界界界界", error: new InlineTextTooWideError("symbol") },
])("rejects invalid symbol $value", ({ value, error }) => {
  expect(thrown(() => parseSymbol(value, "symbol"))).toStrictEqual(error);
});

it.each([
  ["context", "gauge-used"],
  ["thinking", "off"],
] as const)("rejects text colours for symbol-only %s parts", (id, role) => {
  expect(
    thrown(() =>
      parseAppearance(
        { roles: { [role]: { colour: "text" } } },
        "placement",
        id,
      ),
    ),
  ).toStrictEqual(
    new TextColourNotAllowedError(`placement.roles.${role}.colour`),
  );
});

it("rejects multi-column symbols for repeating gauge parts", () => {
  expect(
    thrown(() =>
      parseAppearance(
        { roles: { "gauge-used": { symbol: "##" } } },
        "top-right[0]",
        "context",
      ),
    ),
  ).toStrictEqual(
    new MultiColumnSymbolError("top-right[0].roles.gauge-used.symbol"),
  );
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
    error: new UnknownWidgetPartError("top-left[1].roles.imaginary"),
  },
  {
    value: { roles: { provider: { symbol: "x" } } },
    error: new SymbolNotAllowedError("top-left[1].roles.provider.symbol"),
  },
  {
    value: { color: "accent" },
    error: new UnknownSettingError("top-left[1].color"),
  },
])("rejects unsupported appearance $value", ({ value, error }) => {
  expect(
    thrown(() => parseAppearance(value, "top-left[1]", "model")),
  ).toStrictEqual(error);
});
