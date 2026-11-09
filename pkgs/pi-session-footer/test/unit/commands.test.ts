import { expect, it } from "vitest";
import {
  completeFooter,
  parseFooterCommand,
  commandHelp,
} from "#footer/application/commands.ts";
it.each([
  ["", { view: "explain", segment: undefined }],
  ["explain", { view: "explain", segment: undefined }],
  ["explain context", { view: "explain", segment: "context" }],
  ["config", { view: "config" }],
  ["help", { view: "help" }],
])("parses supported routes: %s", (args, expected) => {
  expect(parseFooterCommand(args)).toStrictEqual(expected);
});
it.each([
  "quota",
  "overview",
  "usage",
  "workflow",
  "diagnostics",
  "git",
  "presets",
  "reload",
  "config compact",
  "help extra",
  "explain missing",
  "explain model extra",
])("rejects removed or invalid grammar: %s", (args) => {
  expect(parseFooterCommand(args)).toHaveProperty("error");
});
it("uses full-prefix completion and common help definitions", () => {
  expect(
    completeFooter("explain ca")?.map(({ value, label }) => ({ value, label })),
  ).toStrictEqual(
    ["cache", "cache-read", "cache-write"].map((id) => ({
      value: `explain ${id}`,
      label: id,
    })),
  );
  expect(completeFooter("")?.map(({ value }) => value)).toStrictEqual([
    "explain",
    "config",
    "help",
  ]);
  expect(commandHelp()).toStrictEqual([
    "/footer explain [widget]: Explain the displayed footer or one widget",
    "/footer config: Preview and customise the footer",
    "/footer help: Commands, widget catalogue and navigation",
    "/footer explain cache: Explain one widget",
    "/footer: Same as /footer explain",
  ]);
});
