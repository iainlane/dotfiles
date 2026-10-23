import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";
import { record } from "../../src/text.ts";

export default function fixture(pi: ExtensionAPI): void {
  const quiet = process.env.PI_FOOTER_QUIET === "1";
  const resetBase = Date.now();
  let interval: ReturnType<typeof setInterval> | undefined;
  let updates = 0;

  const quota = () => ({
    state: {
      provider: "codex",
      usage: {
        lastSuccessAt: Date.now(),
        accountId: "fixture-account",
        credentialSource: "fixture",
        windows: [
          {
            label: "5h",
            usedPercent: 40,
            resetAt: new Date(resetBase + 7_200_000).toISOString(),
            windowSeconds: 18_000,
          },
          {
            label: "Week",
            usedPercent: 42,
            resetAt: new Date(resetBase + 172_800_000).toISOString(),
            windowSeconds: 604_800,
          },
        ],
      },
    },
  });

  pi.events.on("sub-core:request", (request) => {
    if (record(request) && typeof request.reply === "function")
      request.reply(quota());
  });
  pi.events.on("subagents:rpc:v1:request", (request) => {
    if (!record(request)) return;

    pi.events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      version: 1,
      requestId: request.requestId,
      success: true,
      data:
        request.method === "cost"
          ? { total: 0.25, scope: "fixture" }
          : {
              fleet: {
                version: 1,
                totalActive: quiet ? 0 : 2,
                omitted: 0,
                entries: [],
              },
              asyncSnapshot: {
                kind: "pi-subagents.async-status-snapshot",
                version: 1,
                omitted: {},
                runs: quiet
                  ? []
                  : [
                      { label: "Synthetic failed run", state: "failed" },
                      { label: "Synthetic active run", state: "running" },
                    ],
              },
            },
    });
  });

  pi.registerCommand("fixture-theme", {
    description: "Switch the synthetic footer session's theme",
    handler: async (args, ctx) => {
      const result = ctx.ui.setTheme(args.trim());

      if (!result.success)
        throw new Error(result.error ?? "Theme change failed");
    },
  });

  pi.on("agent_start", () => {
    const path = process.env.PI_FOOTER_MODEL_LOG;

    if (path) writeFileSync(path, "Unexpected model turn");
  });
  pi.on("session_start", (_event, ctx) => {
    const publish = () => {
      pi.events.emit("sub-core:update-current", quota());
      updates++;

      if (process.env.PI_FOOTER_UPDATE_LOG)
        writeFileSync(process.env.PI_FOOTER_UPDATE_LOG, String(updates));
    };

    publish();
    interval = setInterval(publish, 1250);
    pi.events.emit("pilens:diagnostics", {
      v: 1,
      cwd: ctx.cwd,
      seq: 1,
      files: [
        {
          path: "fixture.ts",
          diagnostics: quiet
            ? []
            : [
                { severity: "error", message: "Synthetic error" },
                { severity: "warning", message: "Synthetic warning" },
              ],
        },
      ],
    });

    if (quiet) return;

    pi.events.emit("pi-prs:state", {
      protocol: 1,
      source: "pi-prs",
      repository: "fixture/project",
      branch: "footer-fixture",
      health: "ok",
      updatedAt: Date.now(),
      pullRequest: {
        target: {
          host: "github.com",
          owner: "fixture",
          name: "project",
          number: 123,
          url: "https://github.com/fixture/project/pull/123",
        },
        lifecycle: "open",
        mergeState: "blocked",
        unresolvedThreadCount: 2,
        ci: {
          state: "failed",
          failedCount: 1,
          url: "https://github.com/fixture/project/actions/runs/1",
        },
      },
    });
    ctx.ui.setStatus("plan-mode", "plan: implementation");
    pi.events.emit("subagents:rpc:v1:ready", {});
  });
  pi.on("session_shutdown", () => clearInterval(interval));
}
