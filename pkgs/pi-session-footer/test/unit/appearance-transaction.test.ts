import { expect, it, vi } from "vitest";
import {
  AppearanceTransaction,
  type AppearanceEffects,
} from "#footer/configuration/appearance-transaction.ts";
import { loadSettings } from "#footer/configuration/settings.ts";
import { ExpectedObjectError } from "#footer/configuration/settings-errors.ts";
import {
  SettingsWriteError,
  type SettingsSnapshot,
  type SettingsStore,
} from "#footer/configuration/settings-store.ts";
import { thrown } from "#test/support/thrown.ts";

function fixture() {
  const loaded = loadSettings(
    () => '{"preset":"rich"}',
    "/agent/session-footer.json",
  );
  const source: SettingsSnapshot = {
    loaded,
    base: loaded,
    userPath: "/agent/session-footer.user.json",
    userExists: false,
    revision: "r1",
    destination: {
      kind: "file",
      path: loaded.path,
      newUserFile: false,
      repair: false,
    },
  };
  const save = vi.fn<SettingsStore["save"]>(() => source);
  const effects = {
    store: { load: () => source, save },
    preview: vi.fn<AppearanceEffects["preview"]>(),
    saved: vi.fn<AppearanceEffects["saved"]>(),
    reloaded: vi.fn<AppearanceEffects["reloaded"]>(),
    applied: vi.fn<AppearanceEffects["applied"]>(),
    finished: vi.fn<AppearanceEffects["finished"]>(),
  };
  const transaction = new AppearanceTransaction(
    source,
    { preset: "rich" },
    effects,
  );
  return { source, save, effects, transaction };
}
it("reloads an explicitly reviewed source and discards the previous draft", () => {
  const { transaction, source, effects, save } = fixture();
  transaction.replace({ preset: "minimal" });
  const loaded = loadSettings(() => '{"preset":"compact"}', source.loaded.path);
  const fresh = { ...source, loaded, revision: "r2" };
  transaction.reload(fresh);
  transaction.save();
  expect({
    document: transaction.document,
    writes: save.mock.calls,
    reloaded: effects.reloaded.mock.calls,
    saved: effects.saved.mock.calls,
  }).toStrictEqual({
    document: { preset: "compact" },
    writes: [],
    reloaded: [[fresh]],
    saved: [[fresh]],
  });
});

it("keeps field previews separate from accepted edits and persistent saving", () => {
  const { transaction, save } = fixture();
  transaction.replace({ preset: "compact" });
  transaction.preview({ preset: "minimal" });
  expect({
    draft: transaction.document,
    visible: transaction.presentation,
    writes: save.mock.calls,
  }).toStrictEqual({
    draft: { preset: "compact" },
    visible: { preset: "minimal" },
    writes: [],
  });
  transaction.discardPreview();
  expect(transaction.presentation).toStrictEqual({ preset: "compact" });
  transaction.preview({ preset: "workflow" });
  transaction.acceptPreview();
  transaction.save();
  expect(save.mock.calls).toStrictEqual([
    [
      transaction.source,
      { kind: "write", document: { preset: "workflow" }, confirmed: false },
    ],
  ]);
});
it("preserves the last valid preview when a field is invalid", () => {
  const { transaction } = fixture();
  transaction.preview({ preset: "minimal" });
  expect(
    thrown(() => transaction.preview({ separators: "invalid" })),
  ).toStrictEqual(new ExpectedObjectError("separators"));
  expect(transaction.presentation).toStrictEqual({ preset: "minimal" });
});
it("stages user-file removal and discards it on cancellation", () => {
  const { source, effects, save } = fixture();
  source.userExists = true;
  const transaction = new AppearanceTransaction(
    source,
    { preset: "minimal" },
    effects,
  );
  transaction.resetToBase();
  expect({
    draft: transaction.document,
    reset: transaction.resetting,
    writes: save.mock.calls,
  }).toStrictEqual({ draft: { preset: "rich" }, reset: true, writes: [] });
  transaction.cancel();
  transaction.save(true);
  transaction.replace({ preset: "compact" });
  expect({
    writes: save.mock.calls,
    finished: effects.finished.mock.calls,
    previews: effects.preview.mock.calls,
  }).toStrictEqual({
    writes: [],
    finished: [[]],
    previews: [[{ preset: "rich" }], [undefined]],
  });
});
it("converts a staged reset to a normal write when the base appearance is edited", () => {
  const { source, effects, save } = fixture();
  source.userExists = true;
  const transaction = new AppearanceTransaction(
    source,
    { preset: "minimal" },
    effects,
  );
  transaction.resetToBase();
  transaction.replace({ preset: "workflow" });
  transaction.save(true);
  expect(save.mock.calls).toStrictEqual([
    [
      source,
      { kind: "write", document: { preset: "workflow" }, confirmed: true },
    ],
  ]);
});
it("keeps the draft open and unapplied after an I/O error", () => {
  const { transaction, effects, save } = fixture();
  const error = new SettingsWriteError("/agent/session-footer.json", {
    cause: Object.assign(new Error("Permission denied"), { code: "EACCES" }),
  });
  save.mockImplementation(() => {
    throw error;
  });
  transaction.replace({ preset: "compact" });
  expect(thrown(() => transaction.save())).toBe(error);
  expect({
    draft: transaction.document,
    closed: transaction.closed,
    applied: effects.applied.mock.calls,
    saved: effects.saved.mock.calls,
    finished: effects.finished.mock.calls,
  }).toStrictEqual({
    draft: { preset: "compact" },
    closed: false,
    applied: [],
    saved: [],
    finished: [],
  });
});
it("applies session settings once without writing and ignores stale callbacks", () => {
  const { transaction, effects, save } = fixture();
  transaction.replace({ preset: "compact" });
  transaction.useForSession();
  transaction.cancel();
  transaction.useForSession();
  transaction.preview({ preset: "minimal" });
  expect({
    writes: save.mock.calls,
    applied: effects.applied.mock.calls,
    finished: effects.finished.mock.calls,
    closed: transaction.closed,
  }).toStrictEqual({
    writes: [],
    applied: [[{ preset: "compact" }]],
    finished: [[]],
    closed: true,
  });
});
