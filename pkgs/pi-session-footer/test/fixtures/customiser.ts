import {
  CustomEditor,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { existsSync, watch, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export default function customiserFixture(pi: ExtensionAPI): void {
  pi.registerCommand("fixture-customise", {
    handler: async (args, ctx) => {
      ctx.ui.setEditorText("unchanged draft 界é\nsecond line");
      pi.sendUserMessage(
        args.trim() === "explain" ? "/footer" : "/footer config",
        { expandPromptTemplates: true },
      );
      if (args.trim() === "replace") {
        const trigger = process.env.PI_FOOTER_REPLACE_EDITOR;
        if (trigger === undefined || trigger === "") {
          throw new Error(
            "The replace fixture requires PI_FOOTER_REPLACE_EDITOR.",
          );
        }
        let replaced = false;
        const watcher = watch(dirname(trigger), () => {
          if (replaced || !existsSync(trigger)) {
            return;
          }
          replaced = true;
          watcher.close();
          ctx.ui.setEditorComponent(
            (tui, theme, keys) => new CustomEditor(tui, theme, keys),
          );
        });
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
