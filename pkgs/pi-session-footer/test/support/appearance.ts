import type { AppearanceEffects } from "#footer/configuration/appearance-transaction.ts";
import type { SettingsStore } from "#footer/configuration/settings-store.ts";

/**
 * Effects that do nothing, for tests that observe only a transaction and its
 * settings store. Tests of the controller cover how the footer handles them.
 */
export function storeEffects(store: SettingsStore): AppearanceEffects {
  return {
    store,
    preview() {},
    saved() {},
    reloaded() {},
    applied() {},
    finished() {},
  };
}
