import type { SelectionRow } from "#footer/ui/shared/selection-viewport.ts";
import type { SegmentId } from "#footer/configuration/settings.ts";
import { SECTIONS, type Section } from "./inspector-details.ts";

export const INSPECTOR_SECTIONS = ["explain", ...SECTIONS, "help"] as const;
export type InspectorSection = (typeof INSPECTOR_SECTIONS)[number];
export const SECTION_LABELS = {
  explain: "Explain",
  overview: "Overview",
  quota: "Quota",
  workflow: "Workflow",
  diagnostics: "Diagnostics",
  git: "Git",
  usage: "Usage",
  help: "Help",
} satisfies Record<InspectorSection, string>;
export interface InspectionText {
  value: string;
  colour?: "warning" | "error";
}
export interface InspectionRow extends SelectionRow {
  colour?: "warning" | "error";
  run(): void;
}
export interface InspectionContent {
  summary: InspectionText[];
  rows: InspectionRow[];
}
export type InspectionPage =
  | {
      kind: "menu";
      title: string;
      content(): InspectionContent;
    }
  | {
      kind: "detail";
      title: string;
      lines(): string[];
    };
export interface InspectionNavigation {
  open(page: InspectionPage): void;
  section(section: InspectorSection): void;
  widget(id: SegmentId): void;
  sections(): void;
  customise(): void;
}
export function paragraphs(...values: string[]): InspectionText[] {
  return values.map((value) => ({ value }));
}
export function sectionsRow(navigation: InspectionNavigation): InspectionRow {
  return {
    key: "sections",
    value: "Sections…",
    run: () => navigation.sections(),
  };
}
export function detailRow(
  navigation: InspectionNavigation,
  section: string,
  key: string,
  value: string,
  lines: () => string[],
  description?: string,
): InspectionRow {
  return {
    key,
    value,
    description,
    run: () =>
      navigation.open({
        kind: "detail",
        title: `${section} › ${value}`,
        lines,
      }),
  };
}
export type { Section };
