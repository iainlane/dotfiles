import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface ExplorationResult {
  text: string;
  details: unknown;
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function request(
  events: ExtensionAPI["events"],
  method: "spawn" | "stop",
  params: Record<string, unknown>,
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const requestId = randomUUID();
    const unsubscribe = events.on(
      `subagents:rpc:v1:reply:${requestId}`,
      (reply) => {
        unsubscribe();

        if (
          !record(reply) ||
          reply.version !== 1 ||
          reply.requestId !== requestId
        ) {
          reject(new Error("Invalid exploration response"));
          return;
        }

        if (reply.success !== true) {
          const message = record(reply.error) ? reply.error.message : undefined;
          reject(
            new Error(
              typeof message === "string"
                ? message
                : "Exploration request failed",
            ),
          );
          return;
        }

        resolve(reply.data);
      },
    );

    try {
      events.emit("subagents:rpc:v1:request", {
        version: 1,
        requestId,
        method,
        params,
      });
    } catch (error) {
      unsubscribe();
      reject(error);
    }
  });
}

export async function requestExploration(
  events: ExtensionAPI["events"],
  params: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<ExplorationResult> {
  signal?.throwIfAborted();

  const result = await request(events, "spawn", params);
  if (
    !record(result) ||
    typeof result.text !== "string" ||
    !record(result.details) ||
    typeof result.details.runId !== "string"
  ) {
    throw new Error("Invalid exploration response");
  }

  if (signal?.aborted) {
    await request(events, "stop", { id: result.details.runId });
    signal.throwIfAborted();
  }

  return { text: result.text, details: result.details };
}
