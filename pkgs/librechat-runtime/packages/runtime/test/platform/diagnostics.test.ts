import { expect, it } from "vitest";
import {
  errorDiagnostic,
  redactDiagnostic,
} from "#runtime/platform/diagnostics";

it.each([
  ["Bearer private-value", "Bearer [redacted]"],
  [
    "mongodb://private:secret@example.com/db",
    "mongodb://[redacted]@example.com/db",
  ],
  [
    "HTTPS://operator:private@example.test/path",
    "HTTPS://[redacted]@example.test/path",
  ],
  ["Basic cHJpdmF0ZTp2YWx1ZQ==", "Basic [redacted]"],
  ["Authorization: token ghp_private_value", "Authorization: [redacted]"],
  ['{"password":"prefix\\"private-suffix"}', '{"password":[redacted]}'],
  ['password="first private-suffix', "password=[redacted]"],
  ["password='private value'", "password=[redacted]"],
  ['{"apiKey":"private-value"}', '{"apiKey":[redacted]}'],
  ["Cookie: sid=private; other=private", "Cookie: [redacted]"],
  ["Set-Cookie: sid=private; HttpOnly; Path=/", "Set-Cookie: [redacted]"],
  ["eyJhbGciOiJIUzI1NiJ9.eyJzZWNyZXQiOiJwcml2YXRlIn0.signature", "[redacted]"],
  [
    "-----BEGIN PRIVATE KEY-----\nprivate\n-----END PRIVATE KEY-----",
    "[redacted private key]",
  ],
])("redacts conventional credential text in %s", (input, expected) => {
  expect(redactDiagnostic(input)).toBe(expected);
});

it.each([
  [
    'https://api.example.test/keys("sk_live_123")',
    'https://api.example.test/keys("[redacted]")',
  ],
  [
    "https://api.example.test/keys('sk_live_123')",
    "https://api.example.test/keys('[redacted]')",
  ],
  [
    "https://operator:sk_live_123@example.test/path",
    "https://[redacted]@example.test/path",
  ],
  [
    "mongodb+srv://operator:sk_live_123@example.test/db",
    "mongodb+srv://[redacted]@example.test/db",
  ],
  [
    "https://api.example.test/sk_live_123 failed: HTTP 500",
    "https://api.example.test/[redacted] failed: HTTP 500",
  ],
])(
  "masks a configured secret within a URL without parsing its surrounding prose: %s",
  (message, expected) => {
    const frame = "\n    at request (/fixture/main.ts:1:1)";
    const error = Object.assign(new Error(message), {
      stack: `Error: ${message}${frame}`,
    });
    expect(errorDiagnostic(error, ["sk_live_123"])).toStrictEqual({
      name: "Error",
      message: expected,
      stack: `Error: ${expected}${frame}`,
    });
  },
);

it.each([
  "request https://api.example.test/O'Reilly failed: HTTP 500",
  "http://[::1])",
  "https://[2001:db8::1],",
])("preserves ordinary diagnostic URL text: %s", (message) => {
  expect(redactDiagnostic(message)).toBe(message);
});

it.each([
  '{"set-cookie": [\n  "sid=fixture-private-token",\n  "other=another-private-value"\n]}',
  '{"cookie": [\n  "sid=fixture-private-token",\n  "other=unfinished',
])("omits diagnostic text containing a printed cookie array", (message) => {
  const error = Object.assign(new Error(message), {
    code: "UND_ERR_SOCKET",
    stack: `Error: ${message}\n    at request (/fixture/main.ts:1:1)`,
  });
  expect(errorDiagnostic(error)).toStrictEqual({
    name: "Error",
    message: "[redacted cookie array]",
    code: "UND_ERR_SOCKET",
    stack: "[redacted cookie array]",
  });
});

it("excludes arbitrary attached properties and masks configured credentials", () => {
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

it("redacts known secrets before truncating selected error text", () => {
  const error = Object.assign(
    new Error("x".repeat(8189) + "fixture-private-value"),
    { stack: undefined },
  );
  expect(errorDiagnostic(error, ["fixture-private-value"])).toStrictEqual({
    name: "Error",
    message: "x".repeat(8189) + "[re",
  });
});

it.each([
  [
    "shared-key-value",
    "shared-key-value-refreshed",
    "shared-key-value-refreshed",
  ],
  [
    "a".repeat(64) + "shared",
    "shared-sensitive-suffix",
    "a".repeat(64) + "shared-sensitive-suffix",
  ],
])(
  "masks intersecting known credentials in either registration order",
  (first, second, text) => {
    expect([
      redactDiagnostic(text, [first, second]),
      redactDiagnostic(text, [second, first]),
    ]).toStrictEqual(["[redacted]", "[redacted]"]);
  },
);

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
  "redacts an unfinished %s quote ending in an escape",
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
