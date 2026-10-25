import { expect, it } from "vitest";
import { UsageLedger } from "../src/usage.ts";
import { createSnapshot } from "../src/state.ts";
import { renderFooter } from "../src/render.ts";

it("replays auxiliary records once without changing native totals", () => {
  const ledger = new UsageLedger();
  const call = {
    version: 1,
    id: "request-one",
    source: "btw",
    usage: {
      input: 10,
      output: 2,
      cacheRead: 3,
      cacheWrite: 0,
      cost: { total: 0.25 },
    },
  };
  const entries = [
    {
      id: "native",
      type: "message",
      message: {
        role: "assistant",
        usage: { input: 7, output: 1, cost: { total: 1 } },
      },
    },
    {
      id: "side",
      type: "custom",
      customType: "rpiv-btw:usage:v1",
      data: call,
    },
    {
      id: "duplicate",
      type: "custom",
      customType: "rpiv-btw:usage:v1",
      data: call,
    },
  ];
  ledger.update(entries, entries);
  ledger.update(entries, entries);
  expect({ native: ledger.totals, auxiliary: ledger.auxiliary }).toStrictEqual({
    native: {
      input: 7,
      output: 1,
      cacheRead: 0,
      cacheWrite: 0,
      cost: 1,
      latestHit: 0,
    },
    auxiliary: {
      input: 10,
      output: 2,
      cacheRead: 3,
      cacheWrite: 0,
      cost: 0.25,
      latestHit: undefined,
    },
  });
  const state = createSnapshot(0, "/fixture");
  state.usage = ledger.totals;
  state.auxiliaryUsage = ledger.auxiliary;
  expect(renderFooter(state, 160)[1]).toContain("$1.00  aux $0.25");
  ledger.update([], []);
  ledger.update(entries, entries);
  expect(ledger.auxiliary).toStrictEqual({
    input: 10,
    output: 2,
    cacheRead: 3,
    cacheWrite: 0,
    cost: 0.25,
    latestHit: undefined,
  });
});

it.each([NaN, Infinity, -1, "17"])(
  "ignores malformed usage measurements (%s) without losing later records",
  (input) => {
    const ledger = new UsageLedger();
    ledger.update(
      [
        { id: "invalid", type: "usage", usage: { input, cost: { total: 1 } } },
        {
          id: "valid",
          type: "usage",
          usage: { input: 2, cost: { total: 0.5 } },
        },
      ],
      [],
    );
    expect(ledger.totals).toStrictEqual({
      input: 2,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      cost: 0.5,
      latestHit: undefined,
    });
  },
);
