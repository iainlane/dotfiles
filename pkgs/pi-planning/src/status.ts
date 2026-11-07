import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export interface PlanningStatus {
  readonly sessionId: string;
  readonly active: boolean;
  readonly text?: string;
}

// Keep this wire contract in step with pi-session-footer/src/status.ts.
export function createStatusPublisher(
  events: Pick<ExtensionAPI["events"], "on" | "emit">,
) {
  let latest:
    | Readonly<PlanningStatus & { version: 1; source: "planning" }>
    | undefined;
  let disposed = false;
  const stop = events.on("dotfiles:status:request:v1", (raw: unknown) => {
    if (
      typeof raw === "object" &&
      raw !== null &&
      "version" in raw &&
      raw.version === 1 &&
      "sessionId" in raw &&
      raw.sessionId === latest?.sessionId &&
      latest !== undefined
    ) {
      events.emit("dotfiles:status:v1", latest);
    }
  });
  return {
    publish(status: PlanningStatus): void {
      if (disposed) {
        return;
      }
      latest = Object.freeze({ ...status, version: 1, source: "planning" });
      events.emit("dotfiles:status:v1", latest);
    },
    dispose(): void {
      if (disposed) {
        return;
      }
      disposed = true;
      stop();
      if (latest !== undefined) {
        events.emit(
          "dotfiles:status:v1",
          Object.freeze({
            version: 1,
            source: "planning",
            sessionId: latest.sessionId,
            active: false,
          }),
        );
      }
      latest = undefined;
    },
  };
}
