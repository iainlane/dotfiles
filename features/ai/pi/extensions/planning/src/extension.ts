import { readPlanningSettings } from "./settings.ts";
import { nodeFiles } from "./node-files.ts";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  getAgentDir,
  getMarkdownTheme,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { Text, Markdown } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { registerSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { registerRequiredChildExtensions } from "pi-subagents/required-child-extensions";
import { researchTools } from "./policy.ts";
import { reviewPlan } from "./review.ts";
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
        allowedAgents: ["planning-explore", "planning-plan"],
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
    startInPlan: () => pi.getFlag("plan") === true,
    sendUserMessage: (message, options) => pi.sendUserMessage(message, options),
    requestId: randomUUID,
    transport: {
      events: pi.events,
      requestId: randomUUID,
      after(milliseconds, callback) {
        const timer = setTimeout(callback, milliseconds);
        return () => clearTimeout(timer);
      },
    },
    review: (ctx, plan, signal) =>
      reviewPlan(
        ctx,
        plan,
        signal,
        (content) => new Markdown(content, 1, 0, getMarkdownTheme()),
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
    handler: (args, ctx) =>
      controller.command(args, {
        ...ctx,
        handoff: async ({ parentSession, message }) => {
          await ctx.newSession({
            parentSession,
            withSession: async (replacement) => {
              await replacement.sendUserMessage(message);
            },
          });
        },
      }),
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
    name: "planning_research",
    label: "Planning research",
    reachesTools: () => "all",
    description:
      "Run fresh read-only research. Use explore to locate code and evidence, or plan to assess implementation approaches, trade-offs and verification. Supply a focused brief with requirements, constraints, critical paths and prior findings.",
    parameters: Type.Object({
      role: Type.Union([Type.Literal("explore"), Type.Literal("plan")]),
      brief: Type.String({ minLength: 1 }),
      model: Type.Optional(Type.String()),
      thinking: Type.Optional(
        Type.Union([
          Type.Literal("off"),
          Type.Literal("minimal"),
          Type.Literal("low"),
          Type.Literal("medium"),
          Type.Literal("high"),
          Type.Literal("xhigh"),
          Type.Literal("max"),
        ]),
      ),
    }),
    async execute(_id, params, signal, onUpdate, ctx) {
      return controller.investigate(params, ctx, signal, onUpdate);
    },
    renderCall: (args) => new Text(`Planning ${args.role}`),
    renderResult: (result, options) =>
      new Text(
        options.expanded
          ? result.content
              .filter((item) => item.type === "text")
              .map((item) => item.text)
              .join("\n")
          : "Research report · expand to read",
      ),
  });
  pi.registerTool({
    name: "submit_plan",
    label: "Review plan",
    description:
      "Read the active Markdown plan and request explicit approval for this exact revision. Questions do not approve implementation.",
    parameters: Type.Object({}),
    async execute(_id, _params, signal, _update, ctx) {
      return controller.submit(ctx, signal);
    },
    renderCall: () => new Text("Review plan"),
  });

  pi.on("tool_call", (event, ctx) => controller.toolCall(event, ctx));
  pi.on("before_agent_start", (event, ctx) => controller.prompt(event, ctx));
  pi.on("turn_end", (event, ctx) => controller.turnEnd(event, ctx));
  pi.on("agent_settled", (event) => controller.settled(event));
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
