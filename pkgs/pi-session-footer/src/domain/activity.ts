import type { Activity } from "./state.ts";
import { duration, text } from "#footer/shared/text.ts";

export function inactivity(state: Activity, now: number): string | undefined {
  if (
    state.runningSince === undefined ||
    state.waiting ||
    state.compacting ||
    (state.tool !== undefined && state.tool !== "") ||
    state.outcome === "failed" ||
    state.outcome === "cancelled" ||
    now - state.lastContentAt < 30_000
  ) {
    return undefined;
  }

  return duration(now - state.lastContentAt);
}

export type ActivityEvent =
  | "start"
  | "settled"
  | "wait"
  | "resume"
  | "compact"
  | "compacted"
  | "content";

export class ActivityTracker {
  private readonly state: Activity;
  private readonly tools = new Map<string, string>();

  constructor(state: Activity) {
    this.state = state;
  }

  private pause(now: number): void {
    if (this.state.activeSince !== undefined) {
      this.state.activeMs += now - this.state.activeSince;
    }

    this.state.activeSince = undefined;
  }

  update(event: ActivityEvent, now: number, outcome?: string): void {
    const state = this.state;

    if (event === "start") {
      state.runningSince ??= now;

      if (!state.waiting) {
        state.activeSince ??= now;
      }
      state.lastContentAt = now;
      state.outcome = undefined;
    }

    if (event === "settled") {
      this.pause(now);

      state.runningSince = undefined;
      state.waiting = false;
      state.outcome = outcome ?? state.outcome;

      this.tools.clear();

      state.tool = undefined;
    }

    if (event === "wait") {
      this.pause(now);

      state.waiting = true;
    }

    if (event === "resume") {
      state.waiting = false;

      if (state.runningSince !== undefined) {
        state.activeSince ??= now;
      }
    }

    if (event === "compact") {
      state.compacting = true;
      state.compactingSince = now;

      if (state.activeSince === undefined) {
        state.activeSince = now;
      }
    }

    if (event === "compacted") {
      state.compacting = false;
      state.compactingSince = undefined;

      if (state.runningSince === undefined) {
        this.pause(now);
      }
    }

    if (event === "content") {
      state.lastContentAt = now;
    }
  }

  tool(id: string, name: string | undefined, now: number): void {
    const clean = text(name);
    if (clean === "") {
      this.tools.delete(id);
    } else {
      this.tools.set(id, clean);
    }

    this.state.tool = [...this.tools.values()].join(", ") || undefined;
    this.state.lastContentAt = now;
  }
}
