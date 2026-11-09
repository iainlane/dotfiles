import { record, text } from "#footer/shared/text.ts";

export interface StatusSnapshot {
  readonly version: 1;
  readonly source: string;
  readonly sessionId: string;
  readonly active: boolean;
  readonly text?: string;
}

// Keep this wire contract in step with pi-planning/src/status.ts.
export function readStatus(raw: unknown): StatusSnapshot | undefined {
  if (
    !record(raw) ||
    raw.version !== 1 ||
    typeof raw.source !== "string" ||
    !raw.source ||
    raw.source !== text(raw.source) ||
    typeof raw.sessionId !== "string" ||
    !raw.sessionId ||
    raw.sessionId !== text(raw.sessionId, 1024) ||
    typeof raw.active !== "boolean" ||
    (raw.text !== undefined && typeof raw.text !== "string")
  ) {
    return undefined;
  }
  const status: StatusSnapshot = {
    version: 1,
    source: raw.source,
    sessionId: raw.sessionId,
    active: raw.active,
  };

  if (raw.text === undefined) {
    return Object.freeze(status);
  }

  return Object.freeze({ ...status, text: text(raw.text, 500) });
}
