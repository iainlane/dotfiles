import type { KeybindingsManager } from "@earendil-works/pi-coding-agent";
import type { TUI } from "@earendil-works/pi-tui";
import type { AppearanceTransaction } from "#footer/configuration/appearance-transaction.ts";
import type { Colour } from "#footer/configuration/appearance.ts";
import type { PaintTheme } from "#footer/rendering/segment-text.ts";
import type { SettingsStore } from "#footer/configuration/settings-store.ts";

export interface CustomiserRow {
  id: string;
  label: string;
  description?: string;
  tint?: Colour;
  intent?:
    | "edit"
    | "choose"
    | "add"
    | "save"
    | "use"
    | "open"
    | "retry"
    | "reload";
  run(): void;
}
interface PageBase {
  title: string;
  cancel?(): void;
}
export interface CustomiserMenu extends PageBase {
  kind: "menu";
  rows(): CustomiserRow[];
  selected?: string;
  search?: boolean;
  highlight?(id: string): void;
}
export interface CustomiserInput extends PageBase {
  kind: "input";
  initial: string;
  change(value: string): void;
  confirm(value: string): void;
  hint?(value: string): string;
}
export interface CustomiserDetail extends PageBase {
  kind: "detail";
  lines(): string[];
}
export type CustomiserPage =
  | CustomiserMenu
  | CustomiserInput
  | CustomiserDetail;
export interface CustomiserNavigation {
  open(page: CustomiserPage): void;
  back(): void;
  accept(): void;
  root(): void;
  refresh(): void;
}
export interface CustomiserEnvironment {
  tui: TUI;
  keys: Pick<KeybindingsManager, "matches" | "getKeys">;
  theme(): PaintTheme;
  composerHeight(): number;
  presentationMode(): "composer" | "fallback";
  sessionApplied(): boolean;
  transaction: AppearanceTransaction;
  store: SettingsStore;
  sourceIds(): readonly string[];
  reload(): void;
  homeDirectory: string;
}
