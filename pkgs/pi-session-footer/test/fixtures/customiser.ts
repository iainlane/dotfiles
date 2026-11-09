import {
  CustomEditor,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

export default function customiserFixture(pi: ExtensionAPI): void {
  pi.registerCommand("fixture-customise", {
    handler: async (args, ctx) => {
      ctx.ui.setEditorText("unchanged draft 界é\nsecond line");
      pi.sendUserMessage(
        args.trim() === "explain" ? "/footer" : "/footer config",
        { expandPromptTemplates: true },
      );
      if (args.trim() === "replace") {
        setTimeout(() => {
          ctx.ui.setEditorComponent(
            (tui, theme, keys) => new CustomEditor(tui, theme, keys),
          );
        }, 100);
      }
    },
  });
  pi.on("agent_start", (_event, ctx) => {
    writeFileSync(
      join(ctx.cwd, "unexpected-model-turn"),
      "Unexpected model turn",
    );
  });
}
