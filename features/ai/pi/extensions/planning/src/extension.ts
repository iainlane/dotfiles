import { readPlanningSettings } from "./settings.ts";
import { nodeFiles } from "./node-files.ts";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  getAgentDir,
  SettingsManager,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { registerSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { registerRequiredChildExtensions } from "pi-subagents/required-child-extensions";
import { researchTools } from "./policy.ts";
import { ensureSubagentsIdle, planningAgents } from "./subagents.ts";
import { reviewPlan } from "./review.ts";
import { renderPlanReview } from "./review-render.ts";
import { openPlanEditor } from "./editor.ts";
import { reminderType } from "./prompt.ts";
import { registerPlanningRoles } from "./roles.ts";
import { stateEntry } from "./session.ts";
import { createPlanning } from "./controller.ts";
import { PlanStore } from "./store.ts";

function configureChildren(
  pi: ExtensionAPI,
  sessionId: string,
): (() => void)[] {
  const stops: (() => void)[] = [];
  const settings = readPlanningSettings();
  try {
    const required = registerRequiredChildExtensions({
      sessionId,
      extensions: [
        {
          id: "planning-policy",
          path: fileURLToPath(new URL("../child.ts", import.meta.url)),
        },
      ],
      requireForAllRunners: true,
    });
    stops.push(() => required.dispose());
    const ceiling = registerSubagentCapabilityCeiling({
      sessionId,
      source: "planning",
      ceiling: {
        allowedTools: [...researchTools, ...settings.readOnlyTools],
        allowedAgents: planningAgents,
      },
    });
    stops.push(() => ceiling.dispose());
    for (const registration of registerPlanningRoles(pi, settings)) {
      stops.push(() => registration.dispose());
    }
    return stops;
  } catch (error) {
    for (const stop of stops) {
      stop();
    }
    throw error;
  }
}

export default function planning(pi: ExtensionAPI): void {
  const controller = createPlanning({
    openPlan: (id) =>
      new PlanStore(join(getAgentDir(), "plans"), id, nodeFiles),
    recordSavedState: (state) => pi.appendEntry(stateEntry, state),
    configure: (id) => configureChildren(pi, id),
    readOnlyTools: () => readPlanningSettings().readOnlyTools,
    ensureSubagentsIdle: (signal) => ensureSubagentsIdle(pi.events, signal),
    startInPlan: () => pi.getFlag("plan") === true,
    sendUserMessage: (message, options) => pi.sendUserMessage(message, options),
    requestId: randomUUID,
    review: (ctx, request) =>
      reviewPlan(ctx, request, (path) =>
        openPlanEditor(
          path,
          SettingsManager.inMemory(pi.getSettings()).getExternalEditorCommand(),
        ),
      ),
  });
  pi.registerFlag("plan", {
    description: "Start in Plan mode",
    type: "boolean",
    default: false,
  });
  pi.registerCommand("plan", {
    description:
      "Toggle Plan mode, start planning a task, or review the active plan",
    handler: (args, ctx) => controller.command(args, ctx),
  });
  pi.registerShortcut("ctrl+alt+p", {
    description: "Toggle Plan mode",
    handler: async (ctx) => {
      controller.toggle(ctx);
    },
  });

  pi.registerTool({
    name: "enter_plan_mode",
    label: "Enter Plan mode",
    description:
      "Enter planning before implementation when the task warrants investigation and design.",
    parameters: Type.Object({}),
    outputSchema: Type.Object({
      path: Type.String(),
      instructions: Type.String(),
    }),
    async execute(_id, _params, signal, _update, ctx) {
      return controller.enterTool(ctx, signal);
    },
    renderCall: () => new Text("Enter Plan mode"),
  });
  pi.registerTool({
    name: "submit_plan",
    exposure: "model-only",
    executionMode: "sequential",
    label: "Review plan",
    description:
      "Read the active Markdown plan and request explicit approval for this exact revision. Questions do not approve implementation.",
    parameters: Type.Object({}),
    async execute(_id, _params, signal, onUpdate, ctx) {
      return controller.submit(ctx, signal, onUpdate);
    },
    renderCall: () => new Text("Review plan"),
    renderResult: renderPlanReview,
  });

  pi.on("tool_call", (event, ctx) => controller.toolCall(event, ctx));
  pi.on("before_agent_start", (event, ctx) => controller.prompt(event, ctx));
  pi.on("turn_end", (event, ctx) => controller.turnEnd(event, ctx));
  pi.on("agent_end", (_event, ctx) => controller.verifyClear(ctx));
  pi.on("agent_before_settle", (event, ctx) =>
    controller.beforeSettle(event, ctx),
  );
  pi.on("agent_settled", (event, ctx) => controller.settled(event, ctx));
  pi.on("session_start", (event, ctx) => controller.start(event, ctx));
  pi.on("session_tree", (_event, ctx) => controller.restore(ctx));
  pi.on("session_compact", (_event, ctx) => {
    const content = controller.compact(ctx);
    if (content !== undefined) {
      pi.sendMessage(
        { customType: reminderType, content, display: false },
        { triggerTurn: false },
      );
    }
  });
  pi.on("session_shutdown", () => controller.shutdown());
}
