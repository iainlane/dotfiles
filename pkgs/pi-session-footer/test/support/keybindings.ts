import type { KeybindingsManager as NativeKeybindingsManager } from "@earendil-works/pi-coding-agent";

interface KeybindingsModule {
  KeybindingsManager: typeof NativeKeybindingsManager;
}

function isKeybindingsModule(value: unknown): value is KeybindingsModule {
  return (
    typeof value === "object" &&
    value !== null &&
    "KeybindingsManager" in value &&
    typeof value.KeybindingsManager === "function"
  );
}

const native: unknown = await import(
  new URL(
    "./core/keybindings.js",
    import.meta.resolve("@earendil-works/pi-coding-agent"),
  ).href
);
if (!isKeybindingsModule(native)) {
  throw new Error("Expected the SDK's native keybinding manager");
}

export const KeybindingsManager = native.KeybindingsManager;
