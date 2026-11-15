import { expect, it } from "vitest";
import { AppearanceTransaction } from "#footer/configuration/appearance-transaction.ts";
import type { PresentationDocument } from "#footer/configuration/settings.ts";
import { ExpectedObjectError } from "#footer/configuration/settings-errors.ts";
import { SettingsWriteError } from "#footer/configuration/settings-store.ts";
import { storeEffects } from "#test/support/appearance.ts";
import { MemorySettingsStore } from "#test/support/dependencies.ts";

function fixture(user?: PresentationDocument) {
  const store = new MemorySettingsStore();
  store.stored = '{"preset":"rich"}';
  if (user !== undefined) {
    store.user = JSON.stringify(user);
  }
  const source = store.load();
  const transaction = new AppearanceTransaction(
    source,
    user ?? { preset: "rich" },
    storeEffects(store),
  );
  return { source, store, transaction };
}
it("reloads an explicitly reviewed source and discards the previous draft", () => {
  const { transaction, store } = fixture();
  transaction.replace({ preset: "minimal" });
  store.stored = '{"preset":"compact"}';
  const fresh = store.load();
  transaction.reload(fresh);
  transaction.save();
  expect({
    document: transaction.document,
    source: transaction.source,
    stored: store.load(),
  }).toStrictEqual({
    document: { preset: "compact" },
    source: fresh,
    stored: fresh,
  });
});

it("keeps field previews separate from accepted edits and persistent saving", () => {
  const { transaction, store, source } = fixture();
  transaction.replace({ preset: "compact" });
  transaction.preview({ preset: "minimal" });
  expect({
    draft: transaction.document,
    visible: transaction.presentation,
    stored: store.load(),
  }).toStrictEqual({
    draft: { preset: "compact" },
    visible: { preset: "minimal" },
    stored: source,
  });
  transaction.discardPreview();
  expect(transaction.presentation).toStrictEqual({ preset: "compact" });
  transaction.preview({ preset: "workflow" });
  transaction.acceptPreview();
  transaction.save();
  expect(store.load().loaded.document).toStrictEqual({ preset: "workflow" });
});
it("preserves the last valid preview when a field is invalid", () => {
  const { transaction } = fixture();
  transaction.preview({ preset: "minimal" });
  expect(() => transaction.preview({ separators: "invalid" })).toThrow(
    new ExpectedObjectError("separators"),
  );
  expect(transaction.presentation).toStrictEqual({ preset: "minimal" });
});
it("stages user-file removal and discards it on cancellation", () => {
  const { transaction, store, source } = fixture({ preset: "minimal" });
  transaction.resetToBase();
  expect({
    draft: transaction.document,
    reset: transaction.resetting,
    stored: store.load(),
  }).toStrictEqual({
    draft: { preset: "rich" },
    reset: true,
    stored: source,
  });
  transaction.cancel();
  transaction.save(true);
  transaction.replace({ preset: "compact" });
  expect({
    closed: transaction.closed,
    visible: transaction.presentation,
    stored: store.load(),
  }).toStrictEqual({
    closed: true,
    visible: { preset: "rich" },
    stored: source,
  });
});
it("converts a staged reset to a normal write when the base appearance is edited", () => {
  const { transaction, store } = fixture({ preset: "minimal" });
  transaction.resetToBase();
  transaction.replace({ preset: "workflow" });
  transaction.save(true);
  const saved = store.load();
  expect({
    base: saved.base.document,
    userExists: saved.userExists,
    document: saved.loaded.document,
  }).toStrictEqual({
    base: { preset: "rich" },
    userExists: true,
    document: { preset: "workflow" },
  });
});
it("keeps the draft open and unsaved after an I/O error", () => {
  const { transaction, store, source } = fixture();
  const cause = Object.assign(new Error("Permission denied"), {
    code: "EACCES",
  });
  store.failure = cause;
  transaction.replace({ preset: "compact" });
  expect(() => transaction.save()).toThrow(
    new SettingsWriteError(source.loaded.path, { cause }),
  );
  expect({
    draft: transaction.document,
    closed: transaction.closed,
    stored: store.load(),
  }).toStrictEqual({
    draft: { preset: "compact" },
    closed: false,
    stored: source,
  });
});
it("uses the draft for the session without saving and ignores later calls", () => {
  const { transaction, store, source } = fixture();
  transaction.replace({ preset: "compact" });
  transaction.useForSession();
  transaction.cancel();
  transaction.useForSession();
  transaction.preview({ preset: "minimal" });
  expect({
    closed: transaction.closed,
    visible: transaction.presentation,
    stored: store.load(),
  }).toStrictEqual({
    closed: true,
    visible: { preset: "compact" },
    stored: source,
  });
});
