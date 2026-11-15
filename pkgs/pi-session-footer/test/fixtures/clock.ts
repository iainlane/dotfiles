import { readFileSync, watch } from "node:fs";
import { dirname } from "node:path";
import type { Clock } from "#footer/application/runtime.ts";

interface Timer {
  at: number;
  interval?: number;
  callback: () => void;
}

function clockPath(): string {
  const path = process.env.PI_FOOTER_CLOCK;

  if (path === undefined || path === "") {
    throw new Error("The clock fixture requires PI_FOOTER_CLOCK.");
  }

  return path;
}

/** Returns the time in milliseconds that the test last wrote to the clock file. */
export function fixtureTime(): number {
  return Number(readFileSync(clockPath(), "utf8"));
}

/**
 * A clock whose time is the number in the file at the path in
 * `PI_FOOTER_CLOCK`. The test moves time forward by replacing the file with a
 * later time. The clock then runs, in order, the timers that the new time has
 * passed, with its time set to each timer's due time.
 */
export class FileClock implements Clock {
  private time = fixtureTime();
  private readonly timers = new Set<Timer>();

  constructor() {
    watch(dirname(clockPath()), () => {
      this.advance();
    }).unref();
  }

  now(): number {
    return this.time;
  }

  after(milliseconds: number, callback: () => void): () => void {
    return this.schedule({ at: this.time + milliseconds, callback });
  }

  every(milliseconds: number, callback: () => void): () => void {
    return this.schedule({
      at: this.time + milliseconds,
      interval: milliseconds,
      callback,
    });
  }

  private schedule(timer: Timer): () => void {
    this.timers.add(timer);

    return () => {
      this.timers.delete(timer);
    };
  }

  private advance(): void {
    const end = fixtureTime();

    if (!Number.isFinite(end) || end <= this.time) {
      return;
    }

    for (;;) {
      const next = [...this.timers]
        .filter((timer) => timer.at <= end)
        .toSorted((a, b) => a.at - b.at)[0];

      if (next === undefined) {
        break;
      }

      this.time = next.at;

      if (next.interval === undefined) {
        this.timers.delete(next);
      } else {
        next.at += next.interval;
      }

      next.callback();
    }

    this.time = end;
  }
}
