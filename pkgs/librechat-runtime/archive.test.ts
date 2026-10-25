import { expect, it } from "vitest";
import { ArchiveArgumentsError, archiveArguments } from "./archive.ts";

it.each([
  [
    ["session", "search", "concept", "--hybrid", "--limit", "10"],
    [
      "session",
      "search",
      "--json",
      "--hybrid",
      "--limit",
      "10",
      "--",
      "concept",
    ],
  ],
  [
    ["session", "messages", "session-id", "--around", "10", "--before", "8"],
    [
      "session",
      "messages",
      "--json",
      "--around",
      "10",
      "--before",
      "8",
      "--limit",
      "50",
      "--",
      "session-id",
    ],
  ],
])("accepts bounded archive queries %j", (input, expected) => {
  expect(archiveArguments(input)).toStrictEqual(expected);
});

it.each([
  ["session", "delete", "id"],
  ["session", "messages", "id", "--reveal"],
  ["session", "search", "query", "--server", "http://host"],
  ["session", "search", "query", "--limit", "501"],
  ["session", "search", "query", "--context", "-1"],
  ["session", "search", "query", "--limit", "0"],
  ["session", "search", "query", "--limit", "00"],
  ["session", "search", "query", "--limit", "00000"],
  ["session", "messages", "id", "--limit", "0"],
  ["session", "messages", "id", "--limit", "00"],
  ["session", "messages", "id", "--limit", "00000"],
])("rejects unsafe or unbounded archive queries %j", (...input) => {
  expect(() => archiveArguments(input)).toThrow(ArchiveArgumentsError);
});
