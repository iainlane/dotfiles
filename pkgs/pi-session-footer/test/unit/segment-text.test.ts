import { expect, it } from "vitest";
import type { Theme } from "@earendil-works/pi-coding-agent";
import {
  SegmentPainter,
  paintText,
  truncateText,
} from "#footer/rendering/segment-text.ts";
import { styles } from "#footer/rendering/palette.ts";
import { text } from "#footer/shared/text.ts";

const theme: Pick<Theme, "fg" | "bold" | "style"> = {
  fg: (colour, value) => `<${colour}>${value}</${colour}>`,
  bold: (value) => `<bold>${value}</bold>`,
  style: (value, options) =>
    `<literal:${JSON.stringify(options.fg)}>${value}</literal>`,
};
const p = new SegmentPainter();

it.each([
  ["abcdef", 4, "abc…"],
  ["abcdef", 1, "…"],
  ["abcdef", 0, ""],
  ["界界界", 4, "界…"],
  ["éabcde", 4, "éab…"],
] as const)(
  "keeps shortened source text unpainted: %s/%i",
  (value, width, expected) => {
    expect(text(value, width)).toBe(expected);
  },
);

it.each([0, 1, 2, 3, 5])(
  "captures only symbol fragments visible at width %i",
  (width) => {
    const value = paintText(
      p.symbol(styles.label, "[G]", " main", { primary: true, role: "branch" })
        .runs,
    );
    const actual = truncateText(value, width);
    expect({ value: actual.value, symbols: actual.symbols }).toStrictEqual(
      [
        { value: "", symbols: [] },
        { value: "…", symbols: [] },
        {
          value: "[…",
          symbols: [{ role: "branch", value: "[", colour: "muted" }],
        },
        {
          value: "[G…",
          symbols: [{ role: "branch", value: "[G", colour: "muted" }],
        },
        {
          value: "[G] …",
          symbols: [{ role: "branch", value: "[G]", colour: "muted" }],
        },
      ][[0, 1, 2, 3, 5].indexOf(width)],
    );
  },
);
it("colours the ellipsis like the last kept run", () => {
  const painted = paintText([
    ...p.text(styles.label, "ab").runs,
    ...p.text(styles.text, "cd").runs,
  ]);
  const runs = truncateText(painted, 3).runs.map(({ value, colour }) => ({
    value,
    colour,
  }));
  const kept = painted.runs[0]?.colour;
  expect({ kept, runs }).toStrictEqual({
    kept: "muted",
    runs: [
      { value: "ab", colour: kept },
      { value: "…", colour: kept },
    ],
  });
});
it("preserves grouped hyperlinks without changing the original text", () => {
  const original = p.symbol(styles.text, "G", " main", { primary: true });
  const linked = p.link(original, "https://example.test/pr/1");
  const painted = paintText(linked.runs, { symbol: { colour: "accent" } });
  expect({
    original: original.value,
    value: painted.value,
    targets: painted.runs.map((run) => run.href),
  }).toStrictEqual({
    original: "G main",
    value:
      "\u001B]8;;https://example.test/pr/1\u001B\\G\u001B]8;;\u001B\\\u001B]8;;https://example.test/pr/1\u001B\\ main\u001B]8;;\u001B\\",
    targets: ["https://example.test/pr/1", "https://example.test/pr/1"],
  });
});
it("paints literal symbols and text in independent colours", () => {
  const variant = p.symbol(styles.label, "", " main", {
    primary: true,
    role: "branch",
  });
  expect(
    paintText(
      variant.runs,
      { colour: "text", symbol: { text: "git", colour: "accent" } },
      theme,
    ).value,
  ).toBe("<accent>git</accent><text> main</text>");
});
it("resolves an explicit alias and preserves the default marker for colour-only settings", () => {
  const variant = p.symbol(styles.label, "", "", { primary: true });
  const values = [
    paintText(variant.runs, { symbol: { alias: "model" } }).value,
    paintText(variant.runs, { symbol: "model" }).value,
    paintText(variant.runs, { symbol: { colour: "accent" } }, theme).value,
  ];
  expect(values).toStrictEqual(["", "model", "<accent></accent>"]);
});
it("uses advanced role overrides without flattening an attention state", () => {
  const variant = p.symbol(styles.error, "✗", " failed", {
    primary: true,
    role: "failed",
    attention: true,
  });
  const ordinary = paintText(
    variant.runs,
    { colour: "text", symbol: { colour: "accent" } },
    theme,
  );
  const deliberate = paintText(
    variant.runs,
    {
      colour: "text",
      roles: {
        failed: { colour: "warning", symbol: { text: "!", colour: "success" } },
      },
    },
    theme,
  );
  expect([ordinary.value, deliberate.value]).toStrictEqual([
    "<error>✗ failed</error>",
    "<success>!</success><warning> failed</warning>",
  ]);
});
it("retains a state marker when a state-only widget gets a prefix", () => {
  const variant = p.symbol(styles.activity, "◒", " high", { role: "high" });
  expect(paintText(variant.runs, { symbol: "[T]" }).value).toBe("[T] ◒ high");
});
it("keeps independently styled role markers separate from their text", () => {
  const variant = p.symbol(styles.success, "✚", "1", { role: "staged" });
  expect(
    paintText(
      variant.runs,
      { roles: { staged: { colour: "text", symbol: { colour: "success" } } } },
      theme,
    ).value,
  ).toBe("<success>✚</success><text>1</text>");
});
it("preserves literal custom colours as native concrete colours", () => {
  const variant = p.text(styles.text, "model");
  expect(paintText(variant.runs, { colour: "#123456" }, theme).value).toBe(
    '<literal:{"kind":"rgb","r":18,"g":52,"b":86}>model</literal>',
  );
});
it("materialises default text and keeps typed runs for later placement styling", () => {
  const painted = new SegmentPainter(theme);
  const variant = painted.concat(
    painted.symbol(styles.label, "", " ", { primary: true }),
    painted.text(styles.text, "main"),
  );
  expect({
    value: variant.value,
    unthemed: paintText(variant.runs).value,
  }).toStrictEqual({
    value: "<muted> </muted><text>main</text>",
    unthemed: " main",
  });
});
