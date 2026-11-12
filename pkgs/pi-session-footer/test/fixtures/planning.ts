import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";

export default function fixture(pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setStatus("fff", undefined);
    const log = process.env.PI_FOOTER_START_LOG;
    if (log !== undefined && log !== "") {
      appendFileSync(log, `${ctx.sessionManager.getSessionId()}\n`);
    }
  });
  pi.on("agent_start", () => {
    throw new Error(
      "The cooperative status fixture must not start a model turn",
    );
  });
  pi.registerCommand("fixture-resume", {
    handler: async (_args, ctx) => {
      const session = process.env.PI_FOOTER_SESSION;
      if (session === undefined || session === "") {
        throw new Error("Missing initial session");
      }
      await ctx.switchSession(session);
    },
  });
}
