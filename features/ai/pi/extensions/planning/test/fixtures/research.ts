import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const deferred = ["web_search", "lsp_navigation", "ast_grep_replace"];

export default function researchFixture(pi: ExtensionAPI): void {
  for (const name of [
    "web_enable",
    "pi_lens_activate_tools",
    "inspect_fixture",
    ...deferred,
  ]) {
    pi.registerTool({
      name,
      label: name,
      description: "Offline planning research fixture.",
      exposure: deferred.includes(name) ? "deferred" : "direct",
      parameters: Type.Object({
        operation: Type.Optional(Type.String()),
        apply: Type.Optional(Type.Boolean()),
        tools: Type.Optional(Type.Array(Type.String())),
      }),
      async execute() {
        if (name === "web_enable" || name === "pi_lens_activate_tools") {
          pi.setActiveTools([
            ...new Set([...pi.getActiveTools(), ...deferred]),
          ]);
        }
        return {
          content: [{ type: "text", text: `fixture:${name}` }],
          details: undefined,
        };
      },
    });
  }
  pi.on("session_start", () => {
    pi.setActiveTools(
      pi.getActiveTools().filter((name) => !deferred.includes(name)),
    );
  });
}
