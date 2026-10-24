import { expect, it } from "vitest";
import { ActivityTracker, type ActivityEvent } from "../src/activity.ts";
import { createSnapshot } from "../src/state.ts";

it.each<{
  events: [ActivityEvent, number][];
  activeMs: number;
  lastContentAt: number;
}>([
  {
    events: [
      ["start", 0],
      ["start", 15_000],
      ["settled", 20_000],
    ],
    activeMs: 20_000,
    lastContentAt: 15_000,
  },
  {
    events: [
      ["start", 0],
      ["wait", 5000],
      ["start", 10_000],
      ["resume", 35_000],
      ["resume", 37_000],
      ["settled", 40_000],
    ],
    activeMs: 10_000,
    lastContentAt: 10_000,
  },
])(
  "accounts for repeated lifecycle events: $events",
  ({ events, activeMs, lastContentAt }) => {
    const state = createSnapshot(0, "/fixture").activity;
    const tracker = new ActivityTracker(state);

    for (const [event, now] of events) {
      tracker.update(event, now);
    }

    expect(state).toStrictEqual({
      runningSince: undefined,
      activeSince: undefined,
      activeMs,
      observedSince: 0,
      lastContentAt,
      waiting: false,
      compacting: false,
      compactingSince: undefined,
      tool: undefined,
      outcome: undefined,
    });
  },
);
