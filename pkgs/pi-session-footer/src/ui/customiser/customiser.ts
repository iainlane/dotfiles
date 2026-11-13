import type {
  ExtensionUIContext,
  KeybindingsManager,
} from "@earendil-works/pi-coding-agent";
import { AppearanceTransaction } from "#footer/configuration/appearance-transaction.ts";
import { DockHost } from "#footer/ui/dock/dock-host.ts";
import { DockFocus } from "#footer/ui/dock/dock-focus.ts";
import type { TUI } from "@earendil-works/pi-tui";
import { CustomiserView } from "./customiser-view.ts";
import { createCustomiserRoot } from "./customiser-pages.ts";
import type { CustomiserEnvironment } from "./customiser-page.ts";
import type { PresentationDocument } from "#footer/configuration/settings.ts";
import type {
  SettingsSnapshot,
  SettingsStore,
} from "#footer/configuration/settings-store.ts";
import type { PaintTheme } from "#footer/rendering/segment-text.ts";

export interface CustomiserContext {
  mode: string;
  ui: Pick<
    ExtensionUIContext,
    "setWidget" | "getEditorComponent" | "notify"
  > & { theme: PaintTheme };
}
export interface CustomiserSources {
  store: SettingsStore;
  homeDirectory: string;
  keys(): Pick<KeybindingsManager, "matches" | "getKeys"> | undefined;
  previewLines(): readonly string[];
  composerHeight(): number;
  presentationMode(): "composer" | "fallback";
  sessionApplied(): boolean;
  sourceIds(): readonly string[];
  present(document: PresentationDocument | undefined): void;
  saved(snapshot: SettingsSnapshot): void;
  reloaded(snapshot: SettingsSnapshot): void;
  applied(document: PresentationDocument): void;
}
interface Interaction {
  transaction: AppearanceTransaction;
  host: DockHost;
  visible: boolean;
  preview: PresentationDocument | undefined;
}
export class Customiser {
  private readonly sources: CustomiserSources;
  private current: Interaction | undefined;
  constructor(sources: CustomiserSources) {
    this.sources = sources;
  }

  dispose(): void {
    const current = this.current;
    current?.transaction.cancel();
    current?.host.close();
  }

  async open(
    ctx: CustomiserContext,
    source: SettingsSnapshot,
    document: PresentationDocument,
  ): Promise<void> {
    this.dispose();
    if (ctx.mode !== "tui") {
      ctx.ui.notify("Footer customisation is available in TUI mode.", "info");
      return;
    }
    const keys = this.sources.keys();
    if (keys === undefined) {
      ctx.ui.notify("The footer editor is not ready.", "warning");
      return;
    }
    const factory = ctx.ui.getEditorComponent();
    let interaction: Interaction | undefined;
    let focus: DockFocus | undefined;
    let screen: TUI | undefined;
    const active = () =>
      interaction !== undefined && this.current === interaction;
    const transaction = new AppearanceTransaction(source, document, {
      store: this.sources.store,
      preview: (value) => {
        if (!active() || interaction === undefined) {
          return;
        }
        interaction.preview = value;
        this.sources.present(interaction.visible ? value : undefined);
      },
      saved: (snapshot) => {
        if (!active()) {
          return;
        }
        this.sources.saved(snapshot);
        if (transaction.needsSave) {
          ctx.ui.notify("Footer saved.", "info");
        }
      },
      reloaded: (snapshot) => {
        if (active()) {
          this.sources.reloaded(snapshot);
        }
      },
      applied: (value) => {
        if (!active()) {
          return;
        }
        this.sources.applied(value);
        ctx.ui.notify("Footer applied for this session.", "info");
      },
      finished: () => {
        if (active()) {
          focus?.close();
          interaction?.host.close();
        }
      },
    });
    const host = new DockHost(
      ctx.ui,
      () => active() && ctx.ui.getEditorComponent() === factory,
      {
        keys,
        theme: () => ctx.ui.theme,
        previewLines: () => this.sources.previewLines(),
        setPreviewVisible: (visible) => {
          if (!active() || interaction === undefined) {
            return;
          }
          interaction.visible = visible;
          this.sources.present(visible ? interaction.preview : undefined);
        },
      },
    );
    interaction = {
      transaction,
      host,
      visible: true,
      preview: transaction.document,
    };
    this.current = interaction;
    this.sources.present(transaction.document);
    try {
      const opened = host.open((tui) => {
        screen = tui;
        const env: CustomiserEnvironment = {
          tui,
          keys,
          theme: () => ctx.ui.theme,
          composerHeight: () => this.sources.composerHeight(),
          presentationMode: () => this.sources.presentationMode(),
          sessionApplied: () => this.sources.sessionApplied(),
          transaction,
          store: this.sources.store,
          sourceIds: () => this.sources.sourceIds(),
          homeDirectory: this.sources.homeDirectory,
          reload: () => transaction.reload(this.sources.store.load()),
        };
        return new CustomiserView(env, (navigation) =>
          createCustomiserRoot(env, navigation),
        );
      });
      if (screen !== undefined) {
        focus = DockFocus.attach(
          screen,
          () => ctx.ui.getEditorComponent(),
          active,
        );
      }
      await opened;
    } finally {
      transaction.cancel();
      focus?.close();
      if (this.current === interaction) {
        this.current = undefined;
      }
    }
  }
}
