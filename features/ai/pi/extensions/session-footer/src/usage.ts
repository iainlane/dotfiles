import type { UsageTotals } from "./state.ts";
import { finite, record } from "./text.ts";

function empty(): UsageTotals {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
    latestHit: undefined,
  };
}

function usage(raw: unknown): Omit<UsageTotals, "latestHit"> {
  const value = record(raw) ? raw : {};

  return {
    input: finite(value.input) ?? 0,
    output: finite(value.output) ?? 0,
    cacheRead: finite(value.cacheRead) ?? 0,
    cacheWrite: finite(value.cacheWrite) ?? 0,
    cost: record(value.cost) ? (finite(value.cost.total) ?? 0) : 0,
  };
}

function entryUsage(
  entry: unknown,
): Omit<UsageTotals, "latestHit"> | undefined {
  if (!record(entry)) {
    return undefined;
  }

  if (entry.type === "message" && record(entry.message)) {
    return usage(entry.message.usage);
  }

  if (["usage", "compaction", "branch_summary"].includes(String(entry.type))) {
    return usage(entry.usage);
  }

  return undefined;
}

export class UsageLedger {
  totals = empty();
  auxiliary = empty();
  private readonly auxiliaryIds = new Set<string>();
  private count = 0;
  private lastId: unknown;

  update(entries: readonly unknown[], branch: readonly unknown[]): void {
    const previous = entries[this.count - 1];

    if (
      entries.length < this.count ||
      (this.count > 0 && (!record(previous) || previous.id !== this.lastId))
    ) {
      this.totals = empty();
      this.auxiliary = empty();
      this.auxiliaryIds.clear();
      this.count = 0;
    }

    for (const entry of entries.slice(this.count)) {
      if (
        record(entry) &&
        entry.type === "custom" &&
        entry.customType === "rpiv-btw:usage:v1" &&
        record(entry.data)
      ) {
        const data = entry.data;
        if (
          data.version !== 1 ||
          typeof data.id !== "string" ||
          this.auxiliaryIds.has(data.id) ||
          !record(data.usage)
        ) {
          continue;
        }
        const addition = usage(data.usage);
        if (
          [
            addition.input,
            addition.output,
            addition.cacheRead,
            addition.cacheWrite,
            addition.cost,
          ].some((value) => value < 0)
        ) {
          continue;
        }
        this.auxiliaryIds.add(data.id);
        this.auxiliary.input += addition.input;
        this.auxiliary.output += addition.output;
        this.auxiliary.cacheRead += addition.cacheRead;
        this.auxiliary.cacheWrite += addition.cacheWrite;
        this.auxiliary.cost += addition.cost;
        continue;
      }

      const addition = entryUsage(entry);

      if (!addition) {
        continue;
      }

      this.totals.input += addition.input;
      this.totals.output += addition.output;
      this.totals.cacheRead += addition.cacheRead;
      this.totals.cacheWrite += addition.cacheWrite;
      this.totals.cost += addition.cost;
    }

    this.count = entries.length;

    const last = entries.at(-1);

    this.lastId = record(last) ? last.id : undefined;
    this.totals.latestHit = undefined;

    for (const entry of branch) {
      if (
        !record(entry) ||
        entry.type !== "message" ||
        !record(entry.message) ||
        entry.message.role !== "assistant"
      ) {
        continue;
      }

      const current = usage(entry.message.usage);
      const prompt = current.input + current.cacheRead + current.cacheWrite;

      this.totals.latestHit =
        prompt > 0 ? (current.cacheRead / prompt) * 100 : undefined;
    }
  }
}
