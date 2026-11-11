import { expect, it } from "vitest";
import assert from "node:assert/strict";
import { parseCommand } from "#cli/definitions/commands";
import { UsageError } from "#cli/application/errors";

it.each([
  ["--yes", "bootstrap", "--email", "you@example.com", "--name", "Your Name"],
  ["bootstrap", "--email", "you@example.com", "--name", "Your Name", "--yes"],
])("parses bootstrap options and confirmations: %j", (...args) => {
  expect(parseCommand(args, "public")).toStrictEqual({
    kind: "bootstrap",
    manifest: undefined,
    email: "you@example.com",
    name: "Your Name",
    passwordFile: undefined,
    yes: true,
  });
});

it("preserves the runtime bootstrap manifest argument", () => {
  expect(
    parseCommand(
      [
        "bootstrap",
        "/deployment.json",
        "--email",
        "you@example.com",
        "--name",
        "Your Name",
        "--password-file",
        "/password",
      ],
      "runtime",
    ),
  ).toStrictEqual({
    kind: "bootstrap",
    manifest: "/deployment.json",
    email: "you@example.com",
    name: "Your Name",
    passwordFile: "/password",
    yes: false,
  });
});

it.each([[], ["--help"], ["bootstrap", "--help"], ["reset", "--help"]])(
  "provides public help without a manifest: %j",
  (...args) => {
    const result = parseCommand(args, "public");
    assert.ok(result.kind === "help");
    expect(result.text).toContain("librechatctl");
    expect(result.text).toContain("--yes");
    expect(result.text).not.toContain("<MANIFEST>");
  },
);

it("reports the version", () => {
  expect(parseCommand(["--version"], "public")).toStrictEqual({
    kind: "version",
    text: "librechatctl 0.1.0",
  });
});

it.each([
  ["bootstrap", "--email", "invalid"],
  ["bootstrap", "--name", "x"],
  ["bootstrap", "--password-file", ""],
  ["reset", "--conversation", "invalid"],
  ["bootstrap", "--unknown", "secret-value"],
  ["missing-command"],
])("rejects supplied invalid options: %j", (...args) => {
  expect(() => parseCommand(args, "public")).toThrow(/Invalid arguments/u);
});

it.each([
  ["serve", "/manifest.json"],
  ["guest", "/guest.json"],
  ["hook", "/hook.json"],
])("accepts service commands and --yes: %j", (kind, file) => {
  expect(parseCommand(["--yes", kind, file, "--yes"], "runtime")).toStrictEqual(
    { kind, file },
  );
});

it.each(["serve", "guest", "hook"])("requires the %s file", (command) => {
  expect(() => parseCommand([command], "runtime")).toThrow(
    /Invalid arguments/u,
  );
});

it.each([
  ["--yes", "archive", "session", "search", "concept"],
  ["archive", "--yes", "session", "search", "concept"],
  ["archive", "session", "--yes", "search", "concept"],
  ["archive", "session", "search", "concept", "--yes"],
])("accepts --yes throughout nested archive commands: %j", (...args) => {
  expect(parseCommand(args, "runtime")).toStrictEqual({
    kind: "archive",
    query: ["session", "search", "--json", "--limit", "50", "--", "concept"],
  });
});

it("preserves escaped archive query text", () => {
  expect(
    parseCommand(["archive", "session", "search", "--", "--yes"], "runtime"),
  ).toStrictEqual({
    kind: "archive",
    query: ["session", "search", "--json", "--limit", "50", "--", "--yes"],
  });
});

it.each([
  ["archive", "session", "search"],
  ["archive", "session", "search", "first", "--", "extra"],
  ["archive", "session", "search", "--", "x".repeat(4097)],
])(
  "classifies invalid bounded archive queries as usage errors: %j",
  (...args) => {
    expect(() => parseCommand(args, "runtime")).toThrow(UsageError);
  },
);
