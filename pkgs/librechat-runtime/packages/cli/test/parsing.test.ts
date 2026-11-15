import { expect, it } from "vitest";
import { ArchiveArgumentsError } from "@dotfiles/librechat-runtime/archive";
import { parseCommand } from "#cli/definitions/commands";
import {
  ArchiveArgumentsUsageError,
  CommandArgumentsError,
} from "#cli/application/errors";

/**
 * Matches a help intent whose text ends with the given examples. The router
 * renders the text before them.
 */
function helpEndingWith(examples: readonly string[]): unknown {
  const suffix = ["Examples", ...examples.map((example) => `  ${example}`)]
    .join("\n")
    .replaceAll(/[\\^$.*+?()[\]{}|/]/gu, "\\$&");
  const text: unknown = expect.stringMatching(new RegExp(`\n${suffix}$`, "u"));
  return { kind: "help", text };
}

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

it("preserves the runtime reset manifest argument", () => {
  expect(
    parseCommand(
      [
        "reset",
        "/deployment.json",
        "--conversation",
        "00000000-0000-4000-8000-000000000001",
      ],
      "runtime",
    ),
  ).toStrictEqual({
    kind: "reset",
    manifest: "/deployment.json",
    conversation: "00000000-0000-4000-8000-000000000001",
    yes: false,
  });
});

it.each([
  {
    entry: "public",
    args: [],
    examples: [
      "librechatctl bootstrap",
      "librechatctl reset --conversation CONVERSATION_UUID --yes",
    ],
  },
  {
    entry: "public",
    args: ["--help"],
    examples: [
      "librechatctl bootstrap",
      "librechatctl reset --conversation CONVERSATION_UUID --yes",
    ],
  },
  {
    entry: "public",
    args: ["bootstrap", "--help"],
    examples: [
      "librechatctl bootstrap",
      "librechatctl bootstrap --email you@example.com --name 'Your Name' --password-file ./password",
    ],
  },
  {
    entry: "public",
    args: ["reset", "--help"],
    examples: [
      "librechatctl reset",
      "librechatctl --yes reset --conversation CONVERSATION_UUID",
    ],
  },
  {
    entry: "runtime",
    args: [],
    examples: [
      "librechat-runtime bootstrap ./manifest.json",
      "librechat-runtime reset ./manifest.json --conversation CONVERSATION_UUID --yes",
    ],
  },
  {
    entry: "runtime",
    args: ["bootstrap", "--help"],
    examples: [
      "librechat-runtime bootstrap ./manifest.json",
      "librechat-runtime bootstrap ./manifest.json --email you@example.com --name 'Your Name' --password-file ./password",
    ],
  },
  {
    entry: "runtime",
    args: ["reset", "--help"],
    examples: [
      "librechat-runtime reset ./manifest.json",
      "librechat-runtime --yes reset ./manifest.json --conversation CONVERSATION_UUID",
    ],
  },
  {
    entry: "runtime",
    args: ["archive", "session", "search", "--help"],
    examples: [
      "librechat-runtime archive session search 'search text' --limit 50",
    ],
  },
] as const)(
  "returns $entry help for $args with its examples",
  ({ entry, args, examples }) => {
    expect(parseCommand([...args], entry)).toStrictEqual(
      helpEndingWith(examples),
    );
  },
);

it.each(["public", "runtime"] as const)("reports the %s version", (entry) => {
  const text: unknown = expect.stringMatching(/\b0\.1\.0\b/u);
  expect(parseCommand(["--version"], entry)).toStrictEqual({
    kind: "version",
    text,
  });
});

it.each([
  {
    args: ["bootstrap", "--email", "invalid"],
    path: ["bootstrap"],
    fields: ["email"],
  },
  {
    args: ["bootstrap", "--name", "x"],
    path: ["bootstrap"],
    fields: ["name"],
  },
  {
    args: ["bootstrap", "--password-file", ""],
    path: ["bootstrap"],
    fields: ["passwordFile"],
  },
  {
    args: ["reset", "--conversation", "invalid"],
    path: ["reset"],
    fields: ["conversation"],
  },
  {
    args: ["bootstrap", "--unknown", "secret-value"],
    path: ["bootstrap"],
    fields: [],
  },
  {
    args: ["bootstrap", "--conversation", "invalid"],
    path: ["bootstrap"],
    fields: [],
  },
  {
    args: ["reset", "--email", "you@example.com"],
    path: ["reset"],
    fields: [],
  },
  { args: ["bootstrap", "/deployment.json"], path: ["bootstrap"], fields: [] },
  { args: ["reset", "/deployment.json"], path: ["reset"], fields: [] },
  { args: ["missing-command"], path: [], fields: [] },
  { args: ["serve", "/manifest.json"], path: [], fields: [] },
  { args: ["guest", "/guest.json"], path: [], fields: [] },
  { args: ["hook", "/hook.json"], path: [], fields: [] },
  { args: ["archive", "session", "search", "concept"], path: [], fields: [] },
])("rejects public arguments: $args", ({ args, path, fields }) => {
  expect(() => parseCommand(args, "public")).toThrow(
    new CommandArgumentsError("public", path, fields),
  );
});

it.each([
  ["serve", "/manifest.json"],
  ["guest", "/guest.json"],
  ["hook", "/hook.json"],
])("accepts runtime service commands and --yes: %j", (kind, file) => {
  expect(parseCommand(["--yes", kind, file, "--yes"], "runtime")).toStrictEqual(
    { kind, file },
  );
});

it.each([
  { command: "bootstrap", field: "manifest" },
  { command: "reset", field: "manifest" },
  { command: "serve", field: "file" },
  { command: "guest", field: "file" },
  { command: "hook", field: "file" },
])("requires the runtime $command $field", ({ command, field }) => {
  expect(() => parseCommand([command], "runtime")).toThrow(
    new CommandArgumentsError("runtime", [command], [field]),
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
    expect(() => parseCommand(args, "runtime")).toThrow(
      new ArchiveArgumentsUsageError(new ArchiveArgumentsError()),
    );
  },
);
