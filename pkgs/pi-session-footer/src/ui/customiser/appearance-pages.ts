import {
  FOREGROUND_COLOURS,
  SYMBOL_ALIASES,
  WIDGET_ROLES,
  isThemeColour,
  parseColour,
  symbolText,
  type Colour,
  type SymbolAlias,
} from "#footer/configuration/appearance.ts";
import {
  decoration,
  resetAppearanceDocument,
  symbolColour,
  symbolDocument,
  textColourDocument,
  type AppearanceTarget,
  type SymbolEdit,
} from "#footer/configuration/customise-document.ts";
import type { PresentationDocument } from "#footer/configuration/settings.ts";
import type {
  CustomiserEnvironment,
  CustomiserInput,
  CustomiserMenu,
  CustomiserNavigation,
  CustomiserRow,
} from "./customiser-page.ts";

const aliases = Object.keys(SYMBOL_ALIASES).filter((key): key is SymbolAlias =>
  Object.hasOwn(SYMBOL_ALIASES, key),
);
const commonColours: readonly Colour[] = [
  "accent",
  "text",
  "muted",
  "success",
  "warning",
  "error",
];
function colourLabel(colour: Colour | undefined): string {
  if (colour === undefined) {
    return "Default";
  }
  return isThemeColour(colour) ? FOREGROUND_COLOURS[colour] : colour;
}
export class InvalidHexColourError extends Error {
  readonly value: string;

  constructor(value: string) {
    super("Use #RRGGBB");
    this.value = value;
    this.name = "InvalidHexColourError";
  }
}

export class AppearancePages {
  private readonly env: CustomiserEnvironment;
  private readonly navigation: CustomiserNavigation;

  constructor(env: CustomiserEnvironment, navigation: CustomiserNavigation) {
    this.env = env;
    this.navigation = navigation;
  }

  editor(target: AppearanceTarget, title: string): CustomiserMenu {
    return {
      kind: "menu",
      title,
      rows: () => {
        const current = decoration(this.env.transaction.document, target);
        const rows: CustomiserRow[] = [];
        let supportsSymbol = true;
        let supportsText = target.kind === "placement";
        if (target.kind === "placement" && target.role !== undefined) {
          const role = WIDGET_ROLES[target.id][target.role];
          supportsSymbol = role?.symbol === true;
          supportsText = role?.text === true;
        }
        if (supportsSymbol) {
          rows.push(
            {
              id: "symbol",
              label: "Symbol",
              description: symbolText(current.symbol, "Default"),
              run: () => this.navigation.open(this.symbols(target, title)),
            },
            {
              id: "symbol-colour",
              label: "Symbol colour",
              description: colourLabel(symbolColour(current.symbol)),
              run: () =>
                this.navigation.open(this.colours(target, title, "symbol")),
            },
          );
        }
        if (supportsText) {
          rows.push({
            id: "text-colour",
            label: "Text colour",
            description: colourLabel(current.colour),
            run: () =>
              this.navigation.open(this.colours(target, title, "text")),
          });
        }
        if (
          target.kind === "placement" &&
          target.role === undefined &&
          Object.keys(WIDGET_ROLES[target.id]).length > 0
        ) {
          rows.push({
            id: "parts",
            label: "Individual parts…",
            run: () => this.navigation.open(this.parts(target, title)),
          });
        }
        rows.push({
          id: "reset",
          label: "Reset appearance",
          intent: "use",
          run: () => {
            this.env.transaction.replace(
              resetAppearanceDocument(this.env.transaction.document, target),
            );
            this.navigation.refresh();
          },
        });
        return rows;
      },
    };
  }

  private parts(
    target: Extract<AppearanceTarget, { kind: "placement" }>,
    title: string,
  ): CustomiserMenu {
    return {
      kind: "menu",
      title: `${title} › Individual parts`,
      rows: () =>
        Object.entries(WIDGET_ROLES[target.id]).map(([role, definition]) => ({
          id: role,
          label: definition.label,
          description: symbolText(
            decoration(this.env.transaction.document, { ...target, role })
              .symbol,
            "Default",
          ),
          run: () =>
            this.navigation.open(
              this.editor(
                { ...target, role },
                `${title} › ${definition.label}`,
              ),
            ),
        })),
    };
  }

  private symbols(target: AppearanceTarget, title: string): CustomiserMenu {
    const original = this.env.transaction.document;
    const current = decoration(original, target).symbol;
    const options: { id: string; label: string; edit: SymbolEdit }[] = [
      { id: "default", label: "Default", edit: { kind: "default" } },
      ...aliases.map((alias) => ({
        id: `alias:${alias}`,
        label: `${SYMBOL_ALIASES[alias]} ${alias}`,
        edit: { kind: "alias" as const, alias },
      })),
    ];
    let selected = "default";
    if (typeof current === "string" || current?.text !== undefined) {
      selected = "custom";
    }
    if (typeof current === "object" && current.alias !== undefined) {
      selected = `alias:${current.alias}`;
    }
    return {
      kind: "menu",
      title: `${title} › Symbol`,
      selected,
      search: true,
      cancel: () => this.env.transaction.discardPreview(),
      highlight: (id) => {
        const option = options.find((value) => value.id === id);
        if (option) {
          this.env.transaction.preview(
            symbolDocument(original, target, option.edit),
          );
        } else {
          this.env.transaction.discardPreview();
        }
      },
      rows: () => [
        ...options.map((option) => ({
          id: option.id,
          label: option.label,
          intent: "choose" as const,
          run: () => {
            this.env.transaction.replace(
              symbolDocument(original, target, option.edit),
            );
            this.navigation.accept();
          },
        })),
        {
          id: "custom",
          label: "Custom text…",
          intent: "open",
          run: () =>
            this.navigation.open(this.symbolInput(original, target, title)),
        },
      ],
    };
  }

  private symbolInput(
    original: PresentationDocument,
    target: AppearanceTarget,
    title: string,
  ): CustomiserInput {
    const change = (value: string) =>
      this.env.transaction.preview(
        symbolDocument(original, target, { kind: "literal", text: value }),
      );
    return {
      kind: "input",
      title: `${title} › Custom symbol`,
      initial: symbolText(decoration(original, target).symbol, ""),
      change,
      cancel: () => this.env.transaction.discardPreview(),
      confirm: (value) => {
        change(value);
        this.env.transaction.acceptPreview();
        this.navigation.accept();
        this.navigation.accept();
      },
    };
  }

  private colourDocument(
    original: PresentationDocument,
    target: AppearanceTarget,
    kind: "symbol" | "text",
    value: Colour | undefined,
  ): PresentationDocument {
    if (kind === "symbol") {
      return symbolDocument(original, target, { kind: "colour", value });
    }
    return textColourDocument(original, target, value);
  }

  private colours(
    target: AppearanceTarget,
    title: string,
    kind: "symbol" | "text",
  ): CustomiserMenu {
    const original = this.env.transaction.document;
    const current = decoration(original, target);
    const value =
      kind === "symbol" ? symbolColour(current.symbol) : current.colour;
    const heading = `${title} › ${kind === "symbol" ? "Symbol colour" : "Text colour"}`;
    const options: { id: string; value: Colour | undefined }[] = [
      { id: "default", value: undefined },
      ...commonColours.map((colour) => ({ id: colour, value: colour })),
    ];
    if (value !== undefined && !commonColours.includes(value)) {
      options.push({ id: value, value });
    }
    return {
      kind: "menu",
      title: heading,
      selected: value ?? "default",
      cancel: () => this.env.transaction.discardPreview(),
      highlight: (id) => {
        const option = options.find((item) => item.id === id);
        if (option) {
          this.env.transaction.preview(
            this.colourDocument(original, target, kind, option.value),
          );
        } else {
          this.env.transaction.discardPreview();
        }
      },
      rows: () => [
        ...options.map((option) => ({
          id: option.id,
          label: colourLabel(option.value),
          tint: option.value,
          description: option.value === value ? "Current" : undefined,
          intent: "use" as const,
          run: () => {
            this.env.transaction.replace(
              this.colourDocument(original, target, kind, option.value),
            );
            this.navigation.accept();
          },
        })),
        {
          id: "more",
          label: "More theme colours…",
          intent: "open",
          run: () =>
            this.navigation.open(
              this.themeColours(original, target, heading, kind),
            ),
        },
        {
          id: "custom",
          label: "Custom colour…",
          intent: "open",
          run: () =>
            this.navigation.open(
              this.colourInput(original, target, heading, kind, value),
            ),
        },
      ],
    };
  }

  private themeColours(
    original: PresentationDocument,
    target: AppearanceTarget,
    title: string,
    kind: "symbol" | "text",
  ): CustomiserMenu {
    const options = Object.keys(FOREGROUND_COLOURS).filter(
      (value): value is keyof typeof FOREGROUND_COLOURS => isThemeColour(value),
    );
    return {
      kind: "menu",
      title: `${title} › Theme colours`,
      search: true,
      cancel: () => this.env.transaction.discardPreview(),
      highlight: (id) => {
        if (isThemeColour(id)) {
          this.env.transaction.preview(
            this.colourDocument(original, target, kind, id),
          );
        }
      },
      rows: () =>
        options.map((value) => ({
          id: value,
          label: FOREGROUND_COLOURS[value],
          tint: value,
          intent: "use",
          run: () => {
            this.env.transaction.replace(
              this.colourDocument(original, target, kind, value),
            );
            this.navigation.accept();
            this.navigation.accept();
          },
        })),
    };
  }

  private colourInput(
    original: PresentationDocument,
    target: AppearanceTarget,
    title: string,
    kind: "symbol" | "text",
    current: Colour | undefined,
  ): CustomiserInput {
    const change = (value: string) => {
      if (!/^#[\da-f]{6}$/i.test(value)) {
        throw new InvalidHexColourError(value);
      }
      this.env.transaction.preview(
        this.colourDocument(
          original,
          target,
          kind,
          parseColour(value, "colour"),
        ),
      );
    };
    return {
      kind: "input",
      title: `${title} › Custom colour`,
      initial: current?.startsWith("#") === true ? current : "#",
      change,
      cancel: () => this.env.transaction.discardPreview(),
      confirm: (value) => {
        change(value);
        this.env.transaction.acceptPreview();
        this.navigation.accept();
        this.navigation.accept();
      },
    };
  }
}
