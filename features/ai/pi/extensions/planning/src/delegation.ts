import {
  SUBAGENT_DELEGATION_CANCEL_EVENT,
  SUBAGENT_DELEGATION_REQUEST_EVENT,
  SUBAGENT_DELEGATION_RESPONSE_EVENT,
  SUBAGENT_DELEGATION_UPDATE_EVENT,
  type SubagentDelegationRequest,
} from "pi-subagents/delegation";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

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

  const matches = (value: unknown): value is Record<string, unknown> =>
    isRecord(value) &&
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
          if (!matches(value) || typeof value.status !== "string") {
            return;
          }
          finish({
            status: value.status,
            error: typeof value.error === "string" ? value.error : undefined,
            runId: typeof value.runId === "string" ? value.runId : undefined,
            usage: value.usage,
            result:
              isRecord(value.result) &&
              value.result.kind === "text" &&
              typeof value.result.text === "string"
                ? { kind: "text", text: value.result.text }
                : undefined,
          });
        },
      ),
      transport.events.on(
        SUBAGENT_DELEGATION_UPDATE_EVENT,
        (value: unknown) => {
          if (matches(value)) {
            update({
              currentTool:
                typeof value.currentTool === "string"
                  ? value.currentTool
                  : undefined,
              recentOutput:
                typeof value.recentOutput === "string"
                  ? value.recentOutput
                  : undefined,
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
