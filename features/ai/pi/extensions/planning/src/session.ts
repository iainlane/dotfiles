import { Type, type Static } from "typebox";
import { Check } from "typebox/value";
import type { PlanStore } from "./store.ts";

export const stateEntry = "dotfiles:planning:v1";

const savedStateSchema = Type.Object({
  version: Type.Literal(1),
  active: Type.Boolean(),
  sourceSessionId: Type.String(),
  exitReminderPending: Type.Optional(Type.Boolean()),
});
const savedEntrySchema = Type.Object({
  type: Type.Literal("custom"),
  customType: Type.Literal(stateEntry),
  data: savedStateSchema,
});
export type SavedState = Static<typeof savedStateSchema>;

export interface SessionSnapshot {
  id: string;
  branch: readonly unknown[];
}

export class PlanningSession {
  readonly id: string;
  readonly store: PlanStore;
  private operation = new AbortController();
  get signal(): AbortSignal {
    return this.operation.signal;
  }
  active = false;
  private exitReminderPending = false;
  readonly disposers: (() => void)[] = [];

  constructor(
    snapshot: SessionSnapshot,
    open: (sessionId: string) => PlanStore,
    private readonly record: (state: SavedState) => void,
  ) {
    this.id = snapshot.id;
    this.store = open(this.id);
    const entry = snapshot.branch.findLast((candidate) =>
      Check(savedEntrySchema, candidate),
    );
    if (!Check(savedEntrySchema, entry)) {
      return;
    }
    const previous = entry.data;
    this.active = previous.active;
    this.exitReminderPending = previous.exitReminderPending ?? !previous.active;
    if (previous.sourceSessionId === this.id) {
      return;
    }

    if (!this.store.exists()) {
      const source = open(previous.sourceSessionId);
      if (source.exists()) {
        this.store.write(source.read().content);
      }
    }

    this.exitReminderPending = !this.active;
    this.setActive(this.active);
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
    if (active) {
      this.exitReminderPending = false;
    } else if (this.active) {
      this.exitReminderPending = true;
    }
    this.active = active;
    this.save();
    if (!active) {
      this.operation.abort();
      this.release();
    }
  }

  consumeExitReminder(): boolean {
    if (!this.exitReminderPending) {
      return false;
    }
    this.exitReminderPending = false;
    this.save();
    return true;
  }

  private save(): void {
    this.record({
      version: 1,
      active: this.active,
      sourceSessionId: this.id,
      exitReminderPending: this.exitReminderPending,
    });
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
