import { Type } from "typebox";
import { Check } from "typebox/value";
import {
  SUBAGENT_DELEGATION_CANCEL_EVENT,
  SUBAGENT_DELEGATION_REQUEST_EVENT,
  SUBAGENT_DELEGATION_RESPONSE_EVENT,
  SUBAGENT_DELEGATION_UPDATE_EVENT,
  type SubagentDelegationRequest,
  type SubagentDelegationStatus,
} from "pi-subagents/delegation";

const identitySchema = Type.Object({
  requestId: Type.String(),
  nodeId: Type.String(),
  ownerRunId: Type.String(),
});
const statuses = [
  "completed",
  "failed",
  "timed_out",
  "cancelled",
  "interrupted",
  "tool_budget_exhausted",
  "structured_output_failed",
  "acceptance_failed",
  "invalid_request",
  "unavailable_context",
  "duplicate_node",
] as const satisfies readonly SubagentDelegationStatus[];
const responseSchema = Type.Object({
  ...identitySchema.properties,
  status: Type.Union(statuses.map((status) => Type.Literal(status))),
  error: Type.Optional(Type.String()),
  runId: Type.Optional(Type.String()),
  usage: Type.Optional(Type.Unknown()),
  result: Type.Optional(
    Type.Union([
      Type.Object({ kind: Type.Literal("text"), text: Type.String() }),
      Type.Object({ kind: Type.Literal("structured"), value: Type.Unknown() }),
    ]),
  ),
});
const updateSchema = Type.Object({
  ...identitySchema.properties,
  currentTool: Type.Optional(Type.String()),
  recentOutput: Type.Optional(Type.String()),
});

export interface ResearchUpdate {
  recentOutput?: string;
  currentTool?: string;
}

export interface ResearchResult {
  status: string;
  error?: string;
  runId?: string;
  usage: unknown;
  result?: { kind: "text"; text: string };
}

export interface ResearchTransport {
  events: {
    on(event: string, callback: (value: unknown) => void): () => void;
    emit(event: string, value: unknown): void;
  };
  requestId(): string;
  after(milliseconds: number, callback: () => void): () => void;
}

export function research(
  transport: ResearchTransport,
  request: Omit<
    SubagentDelegationRequest,
    "requestId" | "nodeId" | "context" | "result"
  >,
  signal: AbortSignal,
  update: (value: ResearchUpdate) => void,
): Promise<ResearchResult> {
  const identity = {
    requestId: transport.requestId(),
    nodeId: transport.requestId(),
    ownerRunId: request.ownerRunId,
  };

  const matches = (value: unknown): boolean =>
    Check(identitySchema, value) &&
    value.requestId === identity.requestId &&
    value.nodeId === identity.nodeId &&
    value.ownerRunId === identity.ownerRunId;

  return new Promise((resolve, reject) => {
    let finished = false;
    const stops: (() => void)[] = [];
    let stopTimer: (() => void) | undefined;
    const finish = (response?: ResearchResult, error?: Error) => {
      if (finished) {
        return;
      }
      finished = true;
      stopTimer?.();
      signal.removeEventListener("abort", cancel);
      for (const stop of stops) {
        stop();
      }
      if (error) {
        reject(error);
      } else if (response) {
        resolve(response);
      }
    };
    const cancel = () => {
      if (finished) {
        return;
      }
      transport.events.emit(SUBAGENT_DELEGATION_CANCEL_EVENT, identity);
      finish(undefined, new Error("Planning research was cancelled."));
    };

    if (signal.aborted) {
      cancel();
      return;
    }
    stops.push(
      transport.events.on(
        SUBAGENT_DELEGATION_RESPONSE_EVENT,
        (value: unknown) => {
          if (!matches(value)) {
            return;
          }
          if (!Check(responseSchema, value)) {
            finish(undefined, new Error("Invalid planning research response."));
            return;
          }
          finish({
            status: value.status,
            error: value.error,
            runId: value.runId,
            usage: value.usage,
            result: value.result?.kind === "text" ? value.result : undefined,
          });
        },
      ),
      transport.events.on(
        SUBAGENT_DELEGATION_UPDATE_EVENT,
        (value: unknown) => {
          if (matches(value) && Check(updateSchema, value)) {
            update({
              currentTool: value.currentTool,
              recentOutput: value.recentOutput,
            });
          }
        },
      ),
    );
    signal.addEventListener("abort", cancel, { once: true });
    stopTimer = transport.after((request.timeoutMs ?? 300_000) + 5_000, () => {
      transport.events.emit(SUBAGENT_DELEGATION_CANCEL_EVENT, identity);
      finish(
        undefined,
        new Error(
          "Planning research timed out. Inspect the brief and retry a smaller investigation.",
        ),
      );
    });
    try {
      transport.events.emit(SUBAGENT_DELEGATION_REQUEST_EVENT, {
        ...request,
        ...identity,
        context: "fresh",
        result: { kind: "text" },
      });
    } catch (error) {
      finish(
        undefined,
        error instanceof Error ? error : new Error(String(error)),
      );
    }
  });
}
