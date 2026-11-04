import { vi } from "vitest";
import type { Clock, FooterRuntime } from "../src/runtime.ts";

export class ManualClock implements Clock {
  private time = Date.UTC(2026, 9, 20, 12);
  private readonly jobs = new Set<{
    at: number;
    interval?: number;
    callback: () => void;
  }>();

  now = (): number => this.time;

  get pending(): number {
    return this.jobs.size;
  }

  set(time: number): void {
    this.time = time;
  }

  after(milliseconds: number, callback: () => void): () => void {
    return this.schedule(milliseconds, callback);
  }

  every(milliseconds: number, callback: () => void): () => void {
    return this.schedule(milliseconds, callback, milliseconds);
  }

  private schedule(
    milliseconds: number,
    callback: () => void,
    interval?: number,
  ): () => void {
    const job = { at: this.time + milliseconds, callback, interval };
    this.jobs.add(job);
    return () => {
      this.jobs.delete(job);
    };
  }

  async advance(milliseconds: number): Promise<void> {
    const end = this.time + milliseconds;
    const next = [...this.jobs]
      .filter((job) => job.at <= end)
      .toSorted((a, b) => a.at - b.at)[0];
    if (!next) {
      this.time = end;
      return;
    }
    this.time = next.at;
    if (next.interval === undefined) {
      this.jobs.delete(next);
    } else {
      next.at += next.interval;
    }
    next.callback();
    await Promise.resolve();
    await this.advance(end - this.time);
  }
}

export function dependencies() {
  let id = 0;
  const clock = new ManualClock();
  const runtime = {
    clock,
    homeDirectory: "/Users/test",
    requestId: () => `request-${++id}`,
    readGit: vi.fn<FooterRuntime["readGit"]>(async () => {}),
    reportError: vi.fn<FooterRuntime["reportError"]>(),
  } satisfies FooterRuntime;
  return runtime;
}
