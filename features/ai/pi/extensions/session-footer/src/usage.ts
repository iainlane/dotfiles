import { Type } from "typebox";
import { Check } from "typebox/value";
import type { UsageTotals } from "./state.ts";
import { record } from "./text.ts";

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

const measurement = Type.Optional(Type.Number({ minimum: 0 }));
const usageSchema = Type.Object({
  input: measurement,
  output: measurement,
  cacheRead: measurement,
  cacheWrite: measurement,
  cost: Type.Optional(Type.Object({ total: measurement })),
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

function usage(raw: unknown): Omit<UsageTotals, "latestHit"> {
  if (!Check(usageSchema, raw)) {
    return empty();
  }
  const value = raw;

  return {
    input: value.input ?? 0,
    output: value.output ?? 0,
    cacheRead: value.cacheRead ?? 0,
    cacheWrite: value.cacheWrite ?? 0,
    cost: value.cost?.total ?? 0,
  };
}

function entryUsage(
  entry: unknown,
): Omit<UsageTotals, "latestHit"> | undefined {
  if (Check(messageEntrySchema, entry)) {
    return usage(entry.message.usage);
  }
  if (Check(aggregateEntrySchema, entry)) {
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
      if (Check(auxiliaryEntrySchema, entry)) {
        const data = entry.data;
        if (this.auxiliaryIds.has(data.id)) {
          continue;
        }
        const addition = usage(data.usage);
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
      if (!Check(assistantEntrySchema, entry)) {
        continue;
      }

      const current = usage(entry.message.usage);
      const prompt = current.input + current.cacheRead + current.cacheWrite;

      this.totals.latestHit =
        prompt > 0 ? (current.cacheRead / prompt) * 100 : undefined;
    }
  }
}
