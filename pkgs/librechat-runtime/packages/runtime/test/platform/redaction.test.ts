import { check } from "recheck";
import { expect, it } from "vitest";
import { redactDiagnostic } from "#runtime/platform/diagnostics";
import { diagnosticPatterns } from "#runtime/platform/redaction";

it(
  "matches every diagnostic pattern in linear time",
  { timeout: 300_000 },
  async () => {
    const patterns = diagnosticPatterns(["fixture-secret"]).map(
      ({ pattern }) => pattern,
    );
    const results = await Promise.all(
      patterns.map(async ({ source, flags }) => {
        const { status } = await check(source, flags, {
          timeout: null,
          randomSeed: 0,
        });
        return { source, status };
      }),
    );

    expect(results).toStrictEqual(
      patterns.map(({ source }) => ({ source, status: "safe" })),
    );
  },
);

it.each([
  ["jwt eyJhbGciOi.eyJzdWIi.c2lnbmF0dXJl end", "jwt [redacted] end"],
  ["prefixeyJhbGciOi.eyJzdWIi.c2lnbmF0dXJl end", "prefix[redacted] end"],
  ["eyeyJhbGciOi.eyJzdWIi.c2ln", "ey[redacted]"],
  ["eyJnot-a-jwt eyJa.b.c", "eyJnot-a-jwt [redacted]"],
  ["api_token=value rest", "api_token=[redacted] rest"],
  ["password_token=value rest", "password_token=[redacted] rest"],
  ["a-b-c-password: 'quoted value' rest", "a-b-c-password: [redacted] rest"],
  ['token="unterminated', "token=[redacted]"],
  ["header\nsecret = [1, 2]\ntrailer", "[redacted credential array]"],
  ["secret: [redacted] and token=[x]", "[redacted credential array]"],
  ["secret: [redacted] only", "secret: [redacted] only"],
  ["first\nSet-Cookie: [a, b]\nlast", "[redacted cookie array]"],
  ["mycookie=[a] stays", "mycookie=[a] stays"],
  [
    "fixture-secret in eyJa.b.c with Bearer abc",
    "[redacted] in [redacted] with Bearer [redacted]",
  ],
])("redacts %j as %j", (input, output) => {
  expect(redactDiagnostic(input, ["fixture-secret"])).toBe(output);
});
