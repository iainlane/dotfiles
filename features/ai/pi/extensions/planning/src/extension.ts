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
import { getNativeClipboard, Text } from "@earendil-works/pi-tui";
import { readClipboardImage } from "./feedback.ts";
import {
  emptyPlanInputSchema,
  enterPlanOutputSchema,
  submitPlanOutputSchema,
} from "./contracts.ts";
import { registerSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { registerRequiredChildExtensions } from "pi-subagents/required-child-extensions";
import { ensureSubagentsIdle, planningAgents } from "./subagents.ts";
import { reviewPlan } from "./review.ts";
import { renderPlanDocument, renderPlanReview } from "./review-render.ts";
import { editorName, openPlanEditor, openPlanEditorInUi } from "./editor.ts";
import {
  enterPlanDescription,
  submitPlanDescription,
  planDisplayType,
  implementationMessageType,
  reminderType,
} from "./prompt.ts";
import { registerPlanningRoles } from "./roles.ts";
import { stateEntry } from "./session.ts";
import { createPlanning } from "./controller.ts";
import { PlanStore } from "./store.ts";
import { registerPlanHeadings } from "./plan-headings.ts";
import { outcomeEntryType, renderPlanningOutcome } from "./outcomes.ts";

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
  registerPlanHeadings(pi, join(getAgentDir(), "plans"));
  const controller = createPlanning({
    openPlan: (id) =>
      new PlanStore(join(getAgentDir(), "plans"), id, nodeFiles),
    recordSavedState: (state) => pi.appendEntry(stateEntry, state),
    recordOutcome: (outcome) => pi.appendEntry(outcomeEntryType, outcome),
    presentPlan: (plan) => pi.appendEntry(planDisplayType, plan),
    configure: (id) => configureChildren(pi, id),
    ensureSubagentsIdle: (signal) => ensureSubagentsIdle(pi.events, signal),
    startInPlan: () => pi.getFlag("plan") === true,
    sendUserMessage: (message, options) => pi.sendUserMessage(message, options),
    sendImplementationMessage: (content, onError) =>
      pi.sendMessage(
        { customType: implementationMessageType, content, display: false },
        { triggerTurn: true, onError },
      ),
    requestId: randomUUID,
    review: (ctx, request) => {
      const settings = SettingsManager.inMemory(pi.getSettings());
      const command = settings.getExternalEditorCommand();
      return reviewPlan(
        ctx,
        {
          ...request,
          readImage: () =>
            request.readImage?.() ??
            readClipboardImage(getNativeClipboard(), settings),
        },
        {
          name: editorName(command),
          open: (path) => openPlanEditor(path, command),
        },
      );
    },
  });
  pi.registerEntryRenderer(planDisplayType, (entry) =>
    renderPlanDocument(entry.data),
  );
  pi.registerEntryRenderer(outcomeEntryType, (entry, options, theme) =>
    renderPlanningOutcome(entry.data, options, theme),
  );
  pi.registerFlag("plan", {
    description: "Start in Plan mode",
    type: "boolean",
    default: false,
  });
  pi.registerCommand("plan", {
    description:
      "Enter or show Plan mode; use exit, open or review, or describe a task",
    handler: (args, ctx) => {
      const command = SettingsManager.inMemory(
        pi.getSettings(),
      ).getExternalEditorCommand();
      return controller.command(args, ctx, {
        name: editorName(command),
        open: (path) => openPlanEditorInUi(ctx, path, command),
      });
    },
  });
  pi.registerShortcut("ctrl+alt+p", {
    description: "Toggle Plan mode",
    handler: async (ctx) => {
      controller.toggle(ctx);
    },
  });

  pi.registerTool({
    name: "enter_plan_mode",
    exposure: "model-only",
    label: "Enter Plan mode",
    executionMode: "sequential",
    description: enterPlanDescription,
    parameters: emptyPlanInputSchema,
    outputSchema: enterPlanOutputSchema,
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
    description: submitPlanDescription,
    parameters: emptyPlanInputSchema,
    outputSchema: submitPlanOutputSchema,
    async execute(_id, _params, signal, onUpdate, ctx) {
      return controller.submit(ctx, signal, onUpdate);
    },
    renderCall: () => new Text("Review plan"),
    renderResult: renderPlanReview,
  });

  pi.on("input", () => controller.input());
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
