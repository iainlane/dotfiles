import { describe, expect, it } from "vitest";
import { rewriteBody, rewriteHeaders } from "../src/rewrite.ts";

describe("API request conversion", () => {
  it("removes only the Claude Code beta and changes the client variant", () => {
    expect(
      Object.fromEntries(
        rewriteHeaders(
          new Headers({
            "user-agent": "claude-cli/2.1.310 (external, cli)",
            "anthropic-beta":
              "oauth-2025-04-20, claude-code-20250219,scope-2026-01-01",
            "x-api-key": "test-key",
            "content-type": "application/json",
          }),
        ),
      ),
    ).toStrictEqual({
      "user-agent": "claude-cli/2.1.310 (external, sdk-cli)",
      "anthropic-beta": "oauth-2025-04-20,scope-2026-01-01",
      "x-api-key": "test-key",
      "content-type": "application/json",
    });
  });

  it.each([
    {
      system: "x-anthropic-billing-header: cc_version=test;\nKeep this.",
      expected: "Keep this.",
    },
    {
      system: [
        { type: "text", text: "x-anthropic-billing-header: test\n" },
        {
          type: "text",
          text: "Keep this.",
          cache_control: { type: "ephemeral" },
        },
      ],
      expected: [
        {
          type: "text",
          text: "Keep this.",
          cache_control: { type: "ephemeral" },
        },
      ],
    },
  ])(
    "removes the attribution line from system prompts",
    ({ system, expected }) => {
      const body = {
        system,
        messages: [
          {
            role: "user",
            content: "x-anthropic-billing-header: retain user text",
          },
        ],
        tools: [{ type: "advisor" }],
        output_config: { effort: "high" },
      };
      expect(
        JSON.parse(
          new TextDecoder().decode(
            rewriteBody(new TextEncoder().encode(JSON.stringify(body))),
          ),
        ),
      ).toStrictEqual({ ...body, system: expected });
    },
  );

  it.each([
    "invalid JSON",
    '{ "system": "Leave this alone." }',
    '{"system":[{"type":"text","text":""}]}',
  ])("preserves requests without the attribution line", (input) => {
    const body = new TextEncoder().encode(input);
    expect(rewriteBody(body)).toStrictEqual(body);
  });
});
