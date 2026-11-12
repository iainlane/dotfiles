import { commandHelp } from "#footer/application/commands.ts";
import { DomainPages } from "./domain-pages.ts";
import { CapturedFooter } from "./explanation.ts";
import {
  detailRow,
  paragraphs,
  sectionsRow,
  INSPECTOR_SECTIONS,
  SECTION_LABELS,
  type InspectionNavigation,
  type InspectionPage,
  type InspectionRow,
  type InspectorSection,
} from "./inspection-page.ts";
import { SEGMENTS } from "#footer/rendering/segments.ts";
import {
  REGION_LABELS,
  SEGMENT_IDS,
  type SegmentId,
} from "#footer/configuration/settings.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";

function widgetTitle(id: SegmentId): string {
  if (id === "cache") {
    return "Cache hit rate";
  }
  if (id === "thinking") {
    return "Reasoning effort";
  }
  if (id === "context") {
    return "Context used";
  }
  return SEGMENTS[id].title;
}
const SECTION_DESCRIPTIONS = {
  explain: "What each displayed field means",
  overview: "Model, context and session",
  quota: "Usage windows and resets",
  workflow: "Tasks and child agents",
  diagnostics: "Findings and pending files",
  git: "Repository and pull request",
  usage: "Costs, tokens and timing",
  help: "Commands and navigation",
} satisfies Record<InspectorSection, string>;
export class InspectionPages {
  private readonly domains: DomainPages;
  constructor(
    private readonly capture: () => CapturedFooter,
    snapshot: () => FooterSnapshot | undefined,
    private readonly navigation: InspectionNavigation,
  ) {
    this.domains = new DomainPages(snapshot, navigation);
  }
  section(section: InspectorSection): InspectionPage {
    if (section === "explain") {
      return this.legend();
    }
    if (section === "help") {
      return this.help();
    }
    return this.domains.page(section);
  }
  private legend(): InspectionPage {
    const captured = this.capture();
    return {
      kind: "menu",
      title: "Explain",
      content: () => ({
        summary:
          captured.entries.length === 0
            ? paragraphs(
                captured.drawn
                  ? "No fields are visible in this layout."
                  : "The footer has not drawn yet.",
              )
            : [],
        rows: [
          ...captured.entries.map((entry): InspectionRow => ({
            key: entry.key,
            value: entry.value,
            description: entry.description,
            run: () => this.navigation.widget(entry.id),
          })),
          sectionsRow(this.navigation),
        ],
      }),
    };
  }
  widget(id: SegmentId): InspectionPage {
    const captured = this.capture();
    const title = `Explain › ${widgetTitle(id)}`;
    const placements = captured.entries.filter((entry) => entry.id === id);
    return {
      kind: "menu",
      title,
      content: () => {
        const reason = captured.reason(id);
        const summary = paragraphs(
          ...captured.summary(id),
          ...(reason === undefined ? [] : [reason]),
        );
        const fields = ["git", "diagnostics", "agents"].includes(id)
          ? captured.fields(id)
          : [];
        const rows = placements.map((entry) =>
          detailRow(
            this.navigation,
            title,
            `value:${entry.key}`,
            entry.value,
            () => [
              entry.value,
              REGION_LABELS[entry.region],
              ...captured.summary(id),
            ],
            REGION_LABELS[entry.region],
          ),
        );
        rows.push(
          ...fields.map((field, index) =>
            detailRow(
              this.navigation,
              title,
              `field:${index}`,
              field.value,
              () => [field.value, field.label, REGION_LABELS[field.region]],
              field.label,
            ),
          ),
          detailRow(
            this.navigation,
            title,
            "rendering",
            "Rendering details",
            () => captured.technical(id),
          ),
          {
            key: "domain",
            value: `Open ${SECTION_LABELS[SEGMENTS[id].section]}`,
            run: () => this.navigation.section(SEGMENTS[id].section),
          },
          sectionsRow(this.navigation),
        );
        return { summary, rows };
      },
    };
  }
  sections(): InspectionPage {
    return {
      kind: "menu",
      title: "Sections",
      content: () => ({
        summary: [],
        rows: [
          ...INSPECTOR_SECTIONS.map((section): InspectionRow => ({
            key: section,
            value: SECTION_LABELS[section],
            description: SECTION_DESCRIPTIONS[section],
            run: () => this.navigation.section(section),
          })),
          {
            key: "customise",
            value: "Customise…",
            description: "Preview and edit the footer",
            run: () => this.navigation.customise(),
          },
        ],
      }),
    };
  }
  private help(): InspectionPage {
    return {
      kind: "menu",
      title: "Help",
      content: () => ({
        summary: paragraphs(...commandHelp()),
        rows: [
          {
            key: "widgets",
            value: "Widget catalogue",
            run: () => this.navigation.open(this.catalogue()),
          },
          detailRow(
            this.navigation,
            "Help",
            "examples",
            "Configuration examples",
            () => [
              "A profile with default widget strings:",
              '{ "preset": "minimal", "top-left": ["directory", "git"] }',
              "Independent symbol and text colours:",
              '{ "top-left": [{ "id": "git", "colour": "text", "symbol": { "alias": "git", "colour": "accent" } }] }',
              "Separators:",
              '{ "separators": { "widgets": " · ", "regions": " │ " } }',
              "Open /footer config to preview and save changes.",
            ],
          ),
          detailRow(this.navigation, "Help", "navigation", "Navigation", () => [
            "Use the displayed bindings to move, page, open and go back.",
            "Sections… opens the section picker. Its optional shortcut is shown when available.",
            "Explanation values remain fixed while you inspect them. Rendering details includes captured widths and fitting decisions.",
            "Customise previews one draft. Save & use commits the draft; cancelling the root discards it.",
          ]),
          sectionsRow(this.navigation),
        ],
      }),
    };
  }
  private catalogue(): InspectionPage {
    return {
      kind: "menu",
      title: "Help › Widget catalogue",
      content: () => ({
        summary: [],
        rows: SEGMENT_IDS.map((id) => ({
          key: id,
          value: widgetTitle(id),
          description: `/footer explain ${id}`,
          run: () => this.navigation.widget(id),
        })),
      }),
    };
  }
}
