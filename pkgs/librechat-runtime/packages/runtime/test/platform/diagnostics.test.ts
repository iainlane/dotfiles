import { expect, it } from "vitest";
import {
  errorDiagnostic,
  redactDiagnostic,
} from "#runtime/platform/diagnostics";

it.each([
  ["Bearer private-value", "Bearer [redacted]"],
  ['{"password":"prefix\\"private-suffix"}', '{"password":[redacted]}'],
  ['password="first private-suffix', "password=[redacted]"],
  [
    "HTTPS://operator:private-value@example.test/path",
    "https://example.test/path",
  ],
  [
    "MoNgOdB://operator:private-value@example.test/path",
    "mongodb://example.test/path",
  ],
  ["Basic cHJpdmF0ZTp2YWx1ZQ==", "Basic [redacted]"],
  ["Authorization: token ghp_private_value", "Authorization: [redacted]"],
  ["mongodb://private:secret@example.com", "mongodb://example.com"],
  [
    "mongodb+srv://private:secret@example.com/db?auth=private",
    "mongodb+srv://example.com/db",
  ],
  ["redis://private:secret@example.com", "redis://example.com"],
  ["rediss://private:secret@example.com", "rediss://example.com"],
  ["postgres://private:secret@example.com/db", "postgres://example.com/db"],
  ['{"apiKey":"private-value"}', '{"apiKey":[redacted]}'],
  ["password='private value'", "password=[redacted]"],
  [
    "https://user:password@example.test/path?token=private#fragment",
    "[redacted]",
  ],
  ["eyJhbGciOiJIUzI1NiJ9.eyJzZWNyZXQiOiJwcml2YXRlIn0.signature", "[redacted]"],
  [
    "-----BEGIN PRIVATE KEY-----\nprivate\n-----END PRIVATE KEY-----",
    "[redacted private key]",
  ],
])("redacts credential text in %s", (input, expected) => {
  expect(redactDiagnostic(input)).toBe(expected);
});

it("excludes arbitrary attached properties and redacts known secrets before truncation", () => {
  const cause = Object.assign(new Error("private-fixture-value"), {
    stack: "Error: private-fixture-value\n    at forward (guest.ts:1:1)",
    request: { authorization: "do-not-log" },
  });
  expect(errorDiagnostic(cause, ["private-fixture-value"])).toStrictEqual({
    name: "Error",
    message: "[redacted]",
    stack: "Error: [redacted]\n    at forward (guest.ts:1:1)",
  });
});

it("redacts overlapping registered credentials in either registration order", () => {
  const first = "shared-key-value";
  const second = `${first}-refreshed`;
  expect([
    redactDiagnostic(second, [first, second]),
    redactDiagnostic(second, [second, first]),
  ]).toStrictEqual(["[redacted]", "[redacted]"]);
});

it("bounds cyclic causes and ignores non-error values", () => {
  const error = Object.assign(new Error("cycle"), { stack: undefined });
  error.cause = error;
  expect({
    error: errorDiagnostic(error),
    nonError: errorDiagnostic({ password: "private" }),
  }).toStrictEqual({
    error: {
      name: "Error",
      message: "cycle",
      cause: {
        name: "OmittedCause",
        message: "The error cause limit was reached.",
      },
    },
    nonError: { name: "NonError", message: "A non-error value was thrown." },
  });
});

it("redacts the union of intersecting registered secrets", () => {
  const first = "a".repeat(64) + "shared";
  const second = "shared-sensitive-suffix";
  expect(redactDiagnostic(first + "-sensitive-suffix", [first, second])).toBe(
    "[redacted]",
  );
});

it("redacts incomplete PEM key material in exception diagnostics", () => {
  const error = Object.assign(
    new Error("-----BEGIN PRIVATE KEY-----\nprivate-key-material"),
    { stack: undefined },
  );
  expect(errorDiagnostic(error)).toStrictEqual({
    name: "Error",
    message: "[redacted private key]",
  });
});

it.each(["password", "Authorization"])(
  "redacts an unfinished %s quote with a dangling escape in exception diagnostics",
  (field) => {
    const error = Object.assign(new Error(field + '="first private-suffix\\'), {
      stack: undefined,
    });
    expect(errorDiagnostic(error)).toStrictEqual({
      name: "Error",
      message: field + "=[redacted]",
    });
  },
);
