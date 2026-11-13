import {
  parsePresentationDocument,
  presentationDocument,
  type PresentationDocument,
} from "./settings.ts";
import type { SettingsSnapshot, SettingsStore } from "./settings-store.ts";

export interface AppearanceEffects {
  store: SettingsStore;
  preview(document: PresentationDocument | undefined): void;
  saved(snapshot: SettingsSnapshot): void;
  reloaded(snapshot: SettingsSnapshot): void;
  applied(document: PresentationDocument): void;
  finished(): void;
}
export class AppearanceTransaction {
  private readonly effects: AppearanceEffects;
  private draft: PresentationDocument;
  private pending: PresentationDocument | undefined;
  private ended = false;
  private removal = false;
  private initial: string;
  private snapshot: SettingsSnapshot;

  constructor(
    source: SettingsSnapshot,
    initial: PresentationDocument,
    effects: AppearanceEffects,
  ) {
    this.effects = effects;
    this.snapshot = source;
    this.draft = parsePresentationDocument(initial);
    this.initial = JSON.stringify(this.draft);
  }
  get source(): SettingsSnapshot {
    return this.snapshot;
  }
  get document(): PresentationDocument {
    return this.draft;
  }
  get presentation(): PresentationDocument {
    return this.pending ?? this.draft;
  }
  get closed(): boolean {
    return this.ended;
  }
  get resetting(): boolean {
    return this.removal;
  }
  get dirty(): boolean {
    return this.removal || JSON.stringify(this.draft) !== this.initial;
  }
  get needsSave(): boolean {
    return (
      this.removal ||
      JSON.stringify(this.draft) !==
        JSON.stringify(presentationDocument(this.source.loaded.document))
    );
  }
  get confirmationNeeded(): boolean {
    if (!this.needsSave) {
      return false;
    }
    if (this.removal) {
      return true;
    }
    const destination = this.source.destination;
    return (
      destination.kind === "file" &&
      (destination.newUserFile || destination.repair)
    );
  }
  reload(source: SettingsSnapshot): void {
    if (this.ended) {
      return;
    }
    this.snapshot = source;
    this.draft = presentationDocument(source.loaded.document);
    this.pending = undefined;
    this.removal = false;
    this.initial = JSON.stringify(this.draft);
    this.effects.reloaded(source);
    this.effects.preview(this.draft);
  }
  replace(value: unknown): void {
    if (this.ended) {
      return;
    }
    this.draft = parsePresentationDocument(value);
    this.pending = undefined;
    this.removal = false;
    this.effects.preview(this.draft);
  }
  preview(value: unknown): void {
    if (this.ended) {
      return;
    }
    this.pending = parsePresentationDocument(value);
    this.effects.preview(this.pending);
  }
  discardPreview(): void {
    if (this.ended) {
      return;
    }
    this.pending = undefined;
    this.effects.preview(this.draft);
  }
  acceptPreview(): void {
    if (this.ended || this.pending === undefined) {
      return;
    }
    this.replace(this.pending);
  }
  resetToBase(): void {
    if (this.ended) {
      return;
    }
    this.draft = presentationDocument(this.source.base.document);
    this.pending = undefined;
    this.removal = this.source.userExists;
    this.effects.preview(this.draft);
  }
  save(confirmed = false): void {
    if (this.ended) {
      return;
    }
    let saved = this.source;
    if (this.needsSave) {
      saved = this.effects.store.save(
        this.source,
        this.removal
          ? { kind: "reset", confirmed }
          : { kind: "write", document: this.draft, confirmed },
      );
    }
    this.ended = true;
    this.effects.saved(saved);
    this.finish();
  }
  useForSession(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.effects.applied(this.draft);
    this.finish();
  }
  cancel(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.finish();
  }
  private finish(): void {
    this.pending = undefined;
    this.effects.preview(undefined);
    this.effects.finished();
  }
}
