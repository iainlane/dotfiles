import { expect, it } from "vitest";
import {
  profileDocument,
  regionDocument,
  resetAppearanceDocument,
  symbolDocument,
  textColourDocument,
  type AppearanceTarget,
} from "#footer/configuration/customise-document.ts";
import type { PresentationDocument } from "#footer/configuration/settings.ts";

const git: AppearanceTarget = {
  kind: "placement",
  region: "top-left",
  id: "git",
};
it("keeps inherited rows implicit when their appearance is unchanged", () => {
  const input: PresentationDocument = { preset: "rich", "top-right": [] };
  expect([
    symbolDocument(input, git, { kind: "default" }),
    symbolDocument(input, git, { kind: "colour", value: undefined }),
    textColourDocument(input, git, undefined),
    resetAppearanceDocument(input, git),
  ]).toStrictEqual([input, input, input, input]);
});
it("keeps the default profile implicit when Rich is already active", () => {
  expect(profileDocument({}, "rich", false)).toStrictEqual({});
});
it("materialises only the inherited row being edited", () => {
  const input: PresentationDocument = { preset: "rich", "top-right": [] };
  expect(
    symbolDocument(input, git, { kind: "colour", value: "accent" }),
  ).toStrictEqual({
    preset: "rich",
    "top-right": [],
    "top-left": [
      "model",
      "thinking",
      "tier",
      "directory",
      { id: "git", symbol: { colour: "accent" } },
      "git-operation",
      "git-conflicts",
      "pr",
    ],
  });
  expect(input).toStrictEqual({ preset: "rich", "top-right": [] });
});
it("keeps literal symbol values and independent resets", () => {
  const input: PresentationDocument = {
    "top-left": [
      { id: "git", colour: "text", symbol: { text: "git", colour: "accent" } },
    ],
  };
  expect([
    symbolDocument(input, git, { kind: "default" }),
    symbolDocument(input, git, { kind: "colour", value: undefined }),
    resetAppearanceDocument(input, git),
  ]).toStrictEqual([
    {
      "top-left": [{ id: "git", colour: "text", symbol: { colour: "accent" } }],
    },
    { "top-left": [{ id: "git", colour: "text", symbol: "git" }] },
    { "top-left": ["git"] },
  ]);
});
it("changes role colours without changing root appearance or other placements", () => {
  const input: PresentationDocument = {
    "top-left": [
      {
        id: "git",
        symbol: { alias: "git" },
        roles: { staged: { symbol: "+" } },
      },
    ],
    "bottom-right": ["git"],
  };
  expect(
    textColourDocument(input, { ...git, role: "staged" }, "text"),
  ).toStrictEqual({
    "top-left": [
      {
        id: "git",
        symbol: { alias: "git" },
        roles: { staged: { colour: "text", symbol: "+" } },
      },
    ],
    "bottom-right": ["git"],
  });
});
it("reviews profile row replacement separately from retaining custom rows", () => {
  const input: PresentationDocument = {
    "top-left": [{ id: "git", symbol: "G" }],
    "top-right": [],
    separators: { widgets: " · " },
  };
  expect([
    profileDocument(input, "compact", false),
    profileDocument(input, "compact", true),
  ]).toStrictEqual([
    { preset: "compact", separators: { widgets: " · " } },
    {
      preset: "compact",
      "top-left": [{ id: "git", symbol: "G" }],
      "top-right": [],
      separators: { widgets: " · " },
    },
  ]);
});
it("preserves explicit empty rows when editing order", () => {
  expect(
    regionDocument(
      { "top-left": ["git", "model"], "bottom-left": [] },
      "top-left",
      (items) => {
        items.reverse();
      },
    ),
  ).toStrictEqual({ "top-left": ["model", "git"], "bottom-left": [] });
});
it("supports arbitrary producer keys without changing message text or prototypes", () => {
  const target: AppearanceTarget = { kind: "source", key: "__proto__" };
  const actual = symbolDocument({}, target, { kind: "alias", alias: "git" });
  expect(actual).toStrictEqual({
    symbols: Object.fromEntries([["__proto__", { alias: "git" }]]),
  });
});
