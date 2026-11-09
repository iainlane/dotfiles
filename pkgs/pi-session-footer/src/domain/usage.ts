import { Type } from "typebox";
import { Check } from "typebox/value";
import type { PromptCache, UsageTotals } from "./state.ts";
import { record } from "#footer/shared/text.ts";

function empty(): UsageTotals {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
    costFromProvider: false,
    latestHit: undefined,
  };
}

const measurement = Type.Optional(Type.Number({ minimum: 0 }));
const usageSchema = Type.Object({
  input: measurement,
  output: measurement,
  cacheRead: measurement,
  cacheWrite: measurement,
  cost: Type.Optional(
    Type.Object({
      total: measurement,
      totalFromProvider: Type.Optional(Type.Boolean()),
    }),
  ),
});
const messageEntrySchema = Type.Object({
  type: Type.Literal("message"),
  message: Type.Object({ usage: Type.Optional(Type.Unknown()) }),
});
const aggregateEntrySchema = Type.Object({
  type: Type.Union([
    Type.Literal("usage"),
    Type.Literal("compaction"),
    Type.Literal("branch_summary"),
  ]),
  usage: Type.Optional(Type.Unknown()),
});
const auxiliaryEntrySchema = Type.Object({
  type: Type.Literal("custom"),
  customType: Type.Literal("rpiv-btw:usage:v1"),
  data: Type.Object({
    version: Type.Literal(1),
    id: Type.String(),
    usage: usageSchema,
  }),
});
const assistantEntrySchema = Type.Object({
  type: Type.Literal("message"),
  message: Type.Object({
    role: Type.Literal("assistant"),
    usage: Type.Optional(Type.Unknown()),
  }),
});

interface UsageRecord extends Omit<
  UsageTotals,
  "costFromProvider" | "latestHit"
> {
  costSource: "provider" | "estimate" | undefined;
}

function usage(raw: unknown): UsageRecord {
  if (!Check(usageSchema, raw)) {
    return { ...empty(), costSource: undefined };
  }
  const value = raw;

  return {
    input: value.input ?? 0,
    output: value.output ?? 0,
    cacheRead: value.cacheRead ?? 0,
    cacheWrite: value.cacheWrite ?? 0,
    cost: value.cost?.total ?? 0,
    costSource:
      value.cost === undefined
        ? undefined
        : value.cost.totalFromProvider === true
          ? "provider"
          : "estimate",
  };
}

class UsageSum {
  readonly totals = empty();
  private costed = 0;
  private billed = 0;
  private uncosted = 0;

  add(entry: UsageRecord): void {
    this.totals.input += entry.input;
    this.totals.output += entry.output;
    this.totals.cacheRead += entry.cacheRead;
    this.totals.cacheWrite += entry.cacheWrite;
    this.totals.cost += entry.cost;

    if (entry.costSource === undefined) {
      if (entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0) {
        this.uncosted += 1;
      }
    } else {
      this.costed += 1;
      if (entry.costSource === "provider") {
        this.billed += 1;
      }
    }
    this.totals.costFromProvider =
      this.costed > 0 && this.billed === this.costed && this.uncosted === 0;
  }
}

function entryUsage(entry: unknown): UsageRecord | undefined {
  if (Check(messageEntrySchema, entry)) {
    return usage(entry.message.usage);
  }
  if (Check(aggregateEntrySchema, entry)) {
    return usage(entry.usage);
  }

  return undefined;
}

export class UsageLedger {
  private promptCache: PromptCache | undefined;
  private session = new UsageSum();
  private auxiliarySum = new UsageSum();
  private readonly auxiliaryIds = new Set<string>();
  private count = 0;
  private lastId: unknown;

  get latestPrompt(): PromptCache | undefined {
    return this.promptCache;
  }

  get totals(): UsageTotals {
    return this.session.totals;
  }

  get auxiliary(): UsageTotals {
    return this.auxiliarySum.totals;
  }

  update(entries: readonly unknown[], branch: readonly unknown[]): void {
    const previous = entries[this.count - 1];

    if (
      entries.length < this.count ||
      (this.count > 0 && (!record(previous) || previous.id !== this.lastId))
    ) {
      this.session = new UsageSum();
      this.auxiliarySum = new UsageSum();
      this.auxiliaryIds.clear();
      this.count = 0;
    }

    for (const entry of entries.slice(this.count)) {
      if (Check(auxiliaryEntrySchema, entry)) {
        const data = entry.data;
        if (this.auxiliaryIds.has(data.id)) {
          continue;
        }
        this.auxiliaryIds.add(data.id);
        this.auxiliarySum.add(usage(data.usage));
        continue;
      }

      const addition = entryUsage(entry);

      if (!addition) {
        continue;
      }

      this.session.add(addition);
    }

    this.count = entries.length;

    const last = entries.at(-1);

    this.lastId = record(last) ? last.id : undefined;
    this.totals.latestHit = undefined;
    this.promptCache = undefined;

    for (const entry of branch) {
      if (!Check(assistantEntrySchema, entry)) {
        continue;
      }

      const current = usage(entry.message.usage);
      const prompt = current.input + current.cacheRead + current.cacheWrite;

      this.promptCache =
        prompt > 0 ? { cached: current.cacheRead, total: prompt } : undefined;
      this.totals.latestHit =
        prompt > 0 ? (current.cacheRead / prompt) * 100 : undefined;
    }
  }
}
