import { expect, it } from "vitest";
import { CapturedFooter } from "#footer/ui/inspection/explanation.ts";
import { layoutFooter } from "#footer/rendering/render.ts";
import { resolveSettings } from "#footer/configuration/settings.ts";
import { createSnapshot } from "#footer/domain/state.ts";
import { parseGitStatus } from "#footer/integrations/git.ts";

it("freezes composite and repeated placements in rendered order without refitting", () => {
  const state = createSnapshot(1000, "/demo");
  state.git = parseGitStatus(
    "# branch.head main\n1 M. N... 100644 100644 100644 a a staged.txt\n? new.txt",
    1000,
  );
  const frame = layoutFooter(
    state,
    { top: 100, bottom: 100 },
    {
      settings: resolveSettings({
        "top-left": [{ id: "git", symbol: "G" }],
        "top-right": [],
        "bottom-left": [],
        "bottom-right": ["git"],
      }),
    },
  );
  const captured = new CapturedFooter(frame);
  const expected = [
    {
      key: "top-left:git",
      id: "git",
      region: "top-left",
      value: "G main ✚1 ?1",
      description: "Git branch and file changes · Top left",
    },
    {
      key: "bottom-right:git",
      id: "git",
      region: "bottom-right",
      value: " main ✚1 ?1",
      description: "Git branch and file changes · Bottom right",
    },
  ];
  frame.placements.length = 0;
  frame.decisions.length = 0;
  expect(captured.entries).toStrictEqual(expected);
  expect(captured.technical("git").join("\n")).toContain("top 100, bottom 100");
});
it("explains individual Git symbols from typed captured roles", () => {
  const state = createSnapshot(1000, "/demo");
  state.git = parseGitStatus("# branch.head main\n? new.txt", 1000);
  const frame = layoutFooter(
    state,
    { top: 100, bottom: 0 },
    {
      settings: resolveSettings({
        "top-left": [{ id: "git", roles: { untracked: { symbol: "U" } } }],
        "top-right": [],
        "bottom-left": [],
        "bottom-right": [],
      }),
    },
  );
  expect(new CapturedFooter(frame).fields("git")).toStrictEqual([
    { region: "top-left", role: "branch", label: "Branch", value: " main" },
    {
      region: "top-left",
      role: "untracked",
      label: "Untracked files",
      value: "U1",
    },
  ]);
});
it("distinguishes missing frames, disabled widgets, absent readings and width omissions", () => {
  const state = createSnapshot(1000, "/demo");
  state.model = "demo-model";
  const frame = layoutFooter(
    state,
    { top: 0, bottom: 0 },
    {
      settings: resolveSettings({
        "top-left": ["model", "quota"],
        "top-right": [],
        "bottom-left": [],
        "bottom-right": [],
      }),
    },
  );
  const captured = new CapturedFooter(frame);
  expect({
    empty: new CapturedFooter(undefined).reason("model"),
    preview: new CapturedFooter({ ...frame, mode: "preview" }).entries,
    disabled: captured.reason("git"),
    unavailable: captured.reason("quota"),
    omitted: captured.reason("model"),
  }).toStrictEqual({
    empty: "The footer has not drawn yet.",
    preview: [],
    disabled: "Not enabled in this layout.",
    unavailable: frame.readings.quota.reason,
    omitted: "Omitted because the footer was too narrow.",
  });
});
