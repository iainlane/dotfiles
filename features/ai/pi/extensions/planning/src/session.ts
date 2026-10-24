import type { PlanStore } from "./store.ts";

export const stateEntry = "dotfiles:planning:v1";

export interface SavedState {
  version: 1;
  active: boolean;
  sourceSessionId: string;
}

function savedState(value: unknown): value is SavedState {
  return (
    typeof value === "object" &&
    value !== null &&
    "version" in value &&
    value.version === 1 &&
    "active" in value &&
    typeof value.active === "boolean" &&
    "sourceSessionId" in value &&
    typeof value.sourceSessionId === "string"
  );
}

export interface SessionSnapshot {
  id: string;
  branch: readonly unknown[];
}

function savedEntry(value: unknown): SavedState | undefined {
  if (
    typeof value !== "object" ||
    value === null ||
    !("type" in value) ||
    value.type !== "custom" ||
    !("customType" in value) ||
    value.customType !== stateEntry ||
    !("data" in value) ||
    !savedState(value.data)
  ) {
    return undefined;
  }
  return value.data;
}

export class PlanningSession {
  readonly id: string;
  readonly store: PlanStore;
  private operation = new AbortController();
  get signal(): AbortSignal {
    return this.operation.signal;
  }
  active = false;
  readonly disposers: (() => void)[] = [];

  constructor(
    snapshot: SessionSnapshot,
    open: (sessionId: string) => PlanStore,
    private readonly record: (state: SavedState) => void,
  ) {
    this.id = snapshot.id;
    this.store = open(this.id);
    const previous = snapshot.branch
      .map(savedEntry)
      .findLast((state) => state !== undefined);
    if (!previous) {
      return;
    }
    this.active = previous.active;
    if (previous.sourceSessionId === this.id) {
      return;
    }

    if (!this.store.exists()) {
      const source = open(previous.sourceSessionId);
      if (source.exists()) {
        this.store.write(source.read().content);
      }
    }

    if (!this.active) {
      this.record({
        version: 1,
        active: false,
        sourceSessionId: this.id,
      });
      return;
    }

    this.setActive(true);
  }

  enter(): void {
    if (!this.store.exists()) {
      this.store.write(
        "# Implementation plan\n\nDraft the recommended approach here.\n",
      );
    }
    this.setActive(true);
  }

  setActive(active: boolean): void {
    if (active && this.operation.signal.aborted) {
      this.operation = new AbortController();
    }
    this.active = active;
    this.record({
      version: 1,
      active,
      sourceSessionId: this.id,
    });
    if (!active) {
      this.operation.abort();
      this.release();
    }
  }

  release(): void {
    for (const dispose of this.disposers.splice(0)) {
      dispose();
    }
  }

  dispose(): void {
    this.operation.abort();
    this.release();
  }
}
