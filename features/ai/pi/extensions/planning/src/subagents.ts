import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Check } from "typebox/value";
import type { PlanningToolCall } from "./policy.ts";

export const planningAgents = ["planning-explore", "planning-plan"] as const;

const launchSchema = Type.Object(
  {
    agent: Type.Union(planningAgents.map((agent) => Type.Literal(agent))),
    task: Type.String({ minLength: 1 }),
    model: Type.Optional(Type.String()),
    cwd: Type.Optional(Type.String()),
    async: Type.Optional(Type.Boolean()),
    output: Type.Optional(Type.Literal(false)),
    options: Type.Optional(
      Type.Object(
        {
          context: Type.Optional(Type.Literal("fresh")),
          artifacts: Type.Optional(Type.Literal(false)),
          mission: Type.Optional(Type.Literal(false)),
          timeoutMs: Type.Optional(Type.Integer({ minimum: 1 })),
          thinking: Type.Optional(
            Type.Union(
              ["off", "minimal", "low", "medium", "high", "xhigh", "max"].map(
                (level) => Type.Literal(level),
              ),
            ),
          ),
        },
        { additionalProperties: false },
      ),
    ),
  },
  { additionalProperties: false },
);
const controlSchema = Type.Object(
  {
    action: Type.Union(
      ["list", "get", "status", "guide", "doctor", "stop", "interrupt"].map(
        (action) => Type.Literal(action),
      ),
    ),
    agent: Type.Optional(Type.String()),
    id: Type.Optional(Type.String()),
    options: Type.Optional(
      Type.Object(
        {
          topic: Type.Optional(Type.String()),
          view: Type.Optional(Type.String()),
          index: Type.Optional(Type.Integer({ minimum: 0 })),
          lines: Type.Optional(Type.Integer({ minimum: 1 })),
        },
        { additionalProperties: false },
      ),
    ),
  },
  { additionalProperties: false },
);

export function subagentPolicy(
  event: PlanningToolCall,
): { block: true; reason: string } | undefined {
  if (Check(controlSchema, event.input)) {
    return undefined;
  }
  if (!Check(launchSchema, event.input)) {
    return {
      block: true,
      reason:
        "Use direct planning-explore or planning-plan calls, or native status and cancellation controls. Workflows, output files and implementation agents are unavailable during planning.",
    };
  }
  event.input.output = false;
  event.input.options = {
    ...event.input.options,
    context: "fresh",
    artifacts: false,
    mission: false,
  };
  return undefined;
}

const statusSchema = Type.Object({
  version: Type.Literal(1),
  requestId: Type.String(),
  success: Type.Literal(true),
  data: Type.Object({
    fleet: Type.Object({ totalActive: Type.Integer({ minimum: 0 }) }),
  }),
});
const identitySchema = Type.Object({ requestId: Type.String() });

export function ensureSubagentsIdle(
  events: Pick<ExtensionAPI["events"], "on" | "emit">,
  signal: AbortSignal,
): Promise<void> {
  signal.throwIfAborted();
  const requestId = randomUUID();
  return new Promise((resolve, reject) => {
    let finished = false;
    let unsubscribe: (() => void) | undefined;
    const finish = (error?: Error) => {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timer);
      unsubscribe?.();
      signal.removeEventListener("abort", cancel);
      if (error) {
        reject(error);
        return;
      }
      resolve();
    };
    const cancel = () =>
      finish(
        new Error("The subagent status check was cancelled.", {
          cause: signal.reason,
        }),
      );
    const timer = setTimeout(
      () =>
        finish(
          new Error(
            "Subagent status is unavailable. Retry before requesting implementation approval.",
          ),
        ),
      5000,
    );
    timer.unref();
    unsubscribe = events.on(
      `subagents:rpc:v1:reply:${requestId}`,
      (value: unknown) => {
        if (Check(identitySchema, value) && value.requestId !== requestId) {
          return;
        }
        if (!Check(statusSchema, value)) {
          finish(
            new Error(
              "Cannot verify subagent status. Retry before requesting implementation approval.",
            ),
          );
          return;
        }
        if (value.data.fleet.totalActive > 0) {
          finish(
            new Error(
              "A subagent is still active. Wait for completion or cancel it before requesting implementation approval.",
            ),
          );
          return;
        }
        finish();
      },
    );
    signal.addEventListener("abort", cancel, { once: true });
    try {
      events.emit("subagents:rpc:v1:request", {
        version: 1,
        requestId,
        method: "status",
        params: {},
        source: { extension: "planning" },
      });
    } catch (error) {
      finish(error instanceof Error ? error : new Error(String(error)));
    }
  });
}
