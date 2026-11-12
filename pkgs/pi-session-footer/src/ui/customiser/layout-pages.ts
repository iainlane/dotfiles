import { AppearancePages } from "./appearance-pages.ts";
import {
  profileDocument,
  regionDocument,
  WidgetNotInRegionError,
} from "#footer/configuration/customise-document.ts";
import { symbolText } from "#footer/configuration/appearance.ts";
import { SEGMENTS } from "#footer/rendering/segments.ts";
import {
  PRESET_IDS,
  REGIONS,
  REGION_LABELS,
  SEGMENT_IDS,
  parsePresentationDocument,
  resolveSettings,
  sourceSymbol,
  widgetId,
  type Preset,
  type PresentationDocument,
  type Region,
  type SegmentId,
  type Separators,
} from "#footer/configuration/settings.ts";
import type {
  CustomiserEnvironment,
  CustomiserInput,
  CustomiserMenu,
  CustomiserNavigation,
  CustomiserRow,
} from "./customiser-page.ts";
import { text } from "#footer/shared/text.ts";

export const PROFILE_LABELS = {
  rich: "Rich",
  compact: "Compact",
  minimal: "Minimal",
  workflow: "Workflow",
} satisfies Record<Preset, string>;
const profileDescriptions = {
  rich: "Identity, workflow and usage",
  compact: "Identity and context",
  minimal: "Directory, Git and context",
  workflow: "Work and attention",
} satisfies Record<Preset, string>;
function separatorDocument(
  input: PresentationDocument,
  key: keyof Separators,
  value: string | undefined,
): PresentationDocument {
  const document = structuredClone(input);
  const separators = { ...document.separators };
  delete separators[key];
  if (value !== undefined) {
    separators[key] = value;
  }
  document.separators = separators;
  return parsePresentationDocument(document);
}
export class MissingSourceIdError extends Error {
  constructor() {
    super("Enter a source ID");
    this.name = "MissingSourceIdError";
  }
}

export class LayoutPages {
  private readonly appearance: AppearancePages;
  constructor(
    private readonly env: CustomiserEnvironment,
    private readonly navigation: CustomiserNavigation,
  ) {
    this.appearance = new AppearancePages(env, navigation);
  }
  profiles(): CustomiserMenu {
    const original = this.env.transaction.document;
    const choose = (preset: Preset) => {
      if (REGIONS.some((region) => original[region] !== undefined)) {
        this.navigation.open(this.profileReview(original, preset));
        return;
      }
      this.env.transaction.replace(profileDocument(original, preset, false));
      this.navigation.accept();
    };
    return {
      kind: "menu",
      title: "Profile",
      selected: original.preset ?? "rich",
      cancel: () => this.env.transaction.discardPreview(),
      highlight: (value) => {
        const preset = PRESET_IDS.find((id) => id === value);
        if (preset !== undefined) {
          this.env.transaction.preview(
            profileDocument(original, preset, false),
          );
        }
      },
      rows: () =>
        PRESET_IDS.map((preset) => ({
          id: preset,
          label: PROFILE_LABELS[preset],
          description: profileDescriptions[preset],
          intent: "choose",
          run: () => choose(preset),
        })),
    };
  }
  private profileReview(
    original: PresentationDocument,
    preset: Preset,
  ): CustomiserMenu {
    const choose = (keep: boolean) => {
      this.env.transaction.replace(profileDocument(original, preset, keep));
      this.navigation.root();
    };
    return {
      kind: "menu",
      title: `Profile › ${PROFILE_LABELS[preset]}`,
      cancel: () => this.env.transaction.discardPreview(),
      highlight: (value) =>
        this.env.transaction.preview(
          profileDocument(original, preset, value === "keep"),
        ),
      rows: () => [
        {
          id: "replace",
          label: "Use profile layout",
          description: "Replace customised rows",
          intent: "choose",
          run: () => choose(false),
        },
        {
          id: "keep",
          label: "Keep customised rows",
          description: "Change the base profile",
          intent: "choose",
          run: () => choose(true),
        },
        {
          id: "back",
          label: "Back",
          intent: "open",
          run: () => this.navigation.back(),
        },
      ],
    };
  }
  widgets(): CustomiserMenu {
    return {
      kind: "menu",
      title: "Widgets",
      rows: () =>
        REGIONS.map((region) => ({
          id: region,
          label: REGION_LABELS[region],
          intent: "open",
          run: () => this.navigation.open(this.region(region)),
        })),
    };
  }
  private region(region: Region): CustomiserMenu {
    return {
      kind: "menu",
      title: `Widgets › ${REGION_LABELS[region]}`,
      rows: () => [
        ...resolveSettings(this.env.transaction.document).regions[region].map(
          (placement) => {
            const id = widgetId(placement);
            return {
              id,
              label: SEGMENTS[id].title,
              description: typeof placement === "string" ? "Default" : "Custom",
              intent: "edit" as const,
              run: () => this.navigation.open(this.placement(region, id)),
            };
          },
        ),
        {
          id: "add",
          label: "Add widget…",
          intent: "add",
          run: () => this.navigation.open(this.addWidget(region)),
        },
        {
          id: "reset",
          label: "Reset row to profile",
          intent: "use",
          run: () => {
            const document = structuredClone(this.env.transaction.document);
            delete document[region];
            this.env.transaction.replace(document);
            this.navigation.refresh();
          },
        },
      ],
    };
  }
  private placement(region: Region, id: SegmentId): CustomiserMenu {
    const title = `${SEGMENTS[id].title} · ${REGION_LABELS[region]}`;
    const move = (offset: number) => {
      this.env.transaction.replace(
        regionDocument(this.env.transaction.document, region, (items) => {
          const index = items.findIndex((item) => widgetId(item) === id);
          const item = items[index];
          if (item === undefined) {
            throw new WidgetNotInRegionError(region, id);
          }
          items.splice(index, 1);
          items.splice(index + offset, 0, item);
        }),
      );
      this.navigation.refresh();
    };
    return {
      kind: "menu",
      title,
      rows: () => {
        const values = resolveSettings(this.env.transaction.document).regions[
          region
        ];
        const index = values.findIndex((item) => widgetId(item) === id);
        const rows: CustomiserRow[] = [];
        if (index > 0) {
          rows.push({
            id: "up",
            label: "Move up",
            intent: "use",
            run: () => move(-1),
          });
        }
        if (index >= 0 && index < values.length - 1) {
          rows.push({
            id: "down",
            label: "Move down",
            intent: "use",
            run: () => move(1),
          });
        }
        rows.push(
          {
            id: "appearance",
            label: "Customise…",
            intent: "edit",
            run: () =>
              this.navigation.open(
                this.appearance.editor(
                  { kind: "placement", region, id },
                  title,
                ),
              ),
          },
          {
            id: "remove",
            label: "Remove",
            intent: "use",
            run: () => {
              this.env.transaction.replace(
                regionDocument(
                  this.env.transaction.document,
                  region,
                  (items) => {
                    const at = items.findIndex((item) => widgetId(item) === id);
                    if (at >= 0) {
                      items.splice(at, 1);
                    }
                  },
                ),
              );
              this.navigation.accept();
            },
          },
        );
        return rows;
      },
    };
  }
  private addWidget(region: Region): CustomiserMenu {
    return {
      kind: "menu",
      title: `Add widget · ${REGION_LABELS[region]}`,
      search: true,
      rows: () => {
        const configured = new Set(
          resolveSettings(this.env.transaction.document).regions[region].map(
            (item) => widgetId(item),
          ),
        );
        return SEGMENT_IDS.filter((id) => !configured.has(id)).map((id) => ({
          id,
          label: SEGMENTS[id].title,
          description: id,
          intent: "add",
          run: () => {
            this.env.transaction.replace(
              regionDocument(this.env.transaction.document, region, (items) => {
                items.push(id);
              }),
            );
            this.navigation.accept();
          },
        }));
      },
    };
  }
  separators(): CustomiserMenu {
    return {
      kind: "menu",
      title: "Separators",
      rows: () => [
        ...(["widgets", "regions"] as const).map((key) => ({
          id: key,
          label:
            key === "widgets" ? "Between widgets" : "Before right-hand group",
          description:
            this.env.transaction.document.separators?.[key]?.replaceAll(
              " ",
              "␠",
            ) ?? "Default",
          intent: "edit" as const,
          run: () => this.navigation.open(this.separator(key)),
        })),
        {
          id: "reset",
          label: "Reset separators",
          intent: "use",
          run: () => {
            this.env.transaction.replace({
              ...this.env.transaction.document,
              separators: undefined,
            });
            this.navigation.refresh();
          },
        },
      ],
    };
  }
  private separator(key: keyof Separators): CustomiserMenu {
    const original = this.env.transaction.document;
    const choices = [
      { id: "default", label: "Default", value: undefined },
      { id: "dot", label: "Dot", value: " · " },
      { id: "ascii", label: "ASCII", value: " | " },
      { id: "none", label: "None", value: "" },
    ];
    return {
      kind: "menu",
      title: `Separators › ${key === "widgets" ? "Between widgets" : "Right-hand group"}`,
      selected:
        choices.find((item) => item.value === original.separators?.[key])?.id ??
        "custom",
      cancel: () => this.env.transaction.discardPreview(),
      highlight: (id) => {
        const choice = choices.find((item) => item.id === id);
        if (choice) {
          this.env.transaction.preview(
            separatorDocument(original, key, choice.value),
          );
        } else {
          this.env.transaction.discardPreview();
        }
      },
      rows: () => [
        ...choices.map((choice) => ({
          id: choice.id,
          label: choice.label,
          intent: "use" as const,
          run: () => {
            this.env.transaction.replace(
              separatorDocument(original, key, choice.value),
            );
            this.navigation.accept();
          },
        })),
        {
          id: "custom",
          label: "Custom…",
          intent: "open",
          run: () => this.navigation.open(this.separatorInput(original, key)),
        },
      ],
    };
  }
  private separatorInput(
    original: PresentationDocument,
    key: keyof Separators,
  ): CustomiserInput {
    const change = (value: string) =>
      this.env.transaction.preview(separatorDocument(original, key, value));
    return {
      kind: "input",
      title: "Custom separator",
      initial: original.separators?.[key] ?? "",
      change,
      hint: (value) => `Spaces: ${value.replaceAll(" ", "␠")}`,
      cancel: () => this.env.transaction.discardPreview(),
      confirm: (value) => {
        change(value);
        this.env.transaction.acceptPreview();
        this.navigation.accept();
        this.navigation.accept();
      },
    };
  }
  sources(): CustomiserMenu {
    return {
      kind: "menu",
      title: "Extension symbols",
      rows: () => {
        const document = this.env.transaction.document;
        const symbols = resolveSettings(document).symbols;
        const ids = [
          ...new Set([
            "planning",
            "default",
            ...Object.keys(document.symbols ?? {}),
            ...this.env.sourceIds(),
          ]),
        ];
        return [
          ...ids.map((key) => ({
            id: `source:${key}`,
            label: text(key),
            description: symbolText(
              document.symbols?.[key],
              sourceSymbol(symbols, key),
            ),
            intent: "edit" as const,
            run: () =>
              this.navigation.open(
                this.appearance.editor(
                  { kind: "source", key },
                  `Extension symbols › ${text(key)}`,
                ),
              ),
          })),
          {
            id: "add-source",
            label: "Add source…",
            intent: "add",
            run: () => this.navigation.open(this.sourceInput()),
          },
        ];
      },
    };
  }
  private sourceInput(): CustomiserInput {
    return {
      kind: "input",
      title: "Extension source ID",
      initial: "",
      change() {},
      confirm: (key) => {
        if (key === "") {
          throw new MissingSourceIdError();
        }
        this.navigation.accept();
        this.navigation.open(
          this.appearance.editor(
            { kind: "source", key },
            `Extension symbols › ${text(key)}`,
          ),
        );
      },
    };
  }
}
