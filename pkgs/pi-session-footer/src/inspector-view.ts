import {
  SelectList,
  matchesKey,
  truncateToWidth,
  visibleWidth,
  type KeyId,
  type SelectItem,
} from "@earendil-works/pi-tui";
import { commandHelp, type FooterRoute } from "./commands.ts";
import {
  configurationLines,
  explainSegment,
  frameSummary,
  presetLines,
} from "./explanation.ts";
import type { InspectorContext, InspectorSources } from "./inspector.ts";
import { SECTIONS, detailsLines } from "./inspector-details.ts";
import { SEGMENTS } from "./segments.ts";
import { PRESET_IDS, SEGMENT_IDS, type SegmentId } from "./settings.ts";
import type { FooterSnapshot } from "./state.ts";
import { text } from "./text.ts";
import { DetailViewport } from "./viewport.ts";

interface InspectorRow extends SelectItem {
  segment?: SegmentId;
}
type ViewFactory = Parameters<InspectorContext["ui"]["custom"]>[0];
type ViewEnvironment = {
  tui: Parameters<ViewFactory>[0];
  theme: Parameters<ViewFactory>[1];
  keys: Parameters<ViewFactory>[2];
};
export const INSPECTOR_SECTIONS = [
  "explain",
  "config",
  ...SECTIONS,
  "help",
] as const;
export type InspectorSection = (typeof INSPECTOR_SECTIONS)[number];
const DESCRIPTIONS = {
  explain: "Captured display, symbols and hidden fields",
  config: "Effective JSON and read-only preset previews",
  overview: "Live identity, context and source messages",
  quota: "Windows, resets, freshness and errors",
  workflow: "Tasks, dependencies and delegation",
  diagnostics: "Received findings and coverage",
  git: "Repository, PR, reviews and checks",
  usage: "Accounting scopes, cache and durations",
  help: "Commands and navigation",
} satisfies Record<InspectorSection, string>;
const ACTIONS = [
  "tui.select.up",
  "tui.select.down",
  "tui.select.pageUp",
  "tui.select.pageDown",
  "tui.select.confirm",
  "tui.select.cancel",
  "tui.input.tab",
] as const;
type Action = (typeof ACTIONS)[number];
const HELP_LINES = [
  ...commandHelp(),
  "All commands are read-only. No model calls, quota fetches, diagnostics probes or PR watching.",
  "Read optional session-footer.json from Pi's selected agent directory. Missing configuration uses rich. Invalid configuration falls back atomically with a diagnostic.",
  "Use native /reload after editing. Presets never apply or save from this inspector.",
  "Use the displayed section and hidden-field shortcuts. Configured navigation always takes precedence. Confirm expands a field; cancel returns or closes. Paging follows visible list capacity or detail viewport height.",
];

export function createInspectorView(
  environment: ViewEnvironment,
  route: FooterRoute,
  data: {
    snapshot: () => FooterSnapshot | undefined;
    sources: InspectorSources;
  },
  done: () => void,
): ReturnType<ViewFactory> {
  const { tui, theme, keys } = environment;
  const { snapshot, sources } = data;
  let section: InspectorSection = route.view;
  let selected = route.view === "explain" ? (route.segment ?? "") : "";
  let selectedSegment = route.view === "explain" ? route.segment : undefined;
  let expanded = Boolean(selected);
  let hidden = false;
  let sectionMenu = false;
  let menuSection: InspectorSection = section;
  let items: InspectorRow[] = [];
  let height = 1;
  let listCapacity = 1;
  const viewport = new DetailViewport();
  const key = (id: Action) =>
    keys
      .getKeys(id)
      .filter(
        (binding) =>
          ACTIONS.find((action) => keys.getKeys(action).includes(binding)) ===
          id,
      )
      .join("/");
  const shortcut = (candidates: readonly KeyId[]) =>
    candidates.find(
      (binding) => !ACTIONS.some((id) => keys.getKeys(id).includes(binding)),
    );
  const sectionsKey = shortcut(["s", "alt+s"]);
  const hiddenKey = shortcut(["h", "alt+h"]);
  const listMode = () =>
    sectionMenu ||
    ((section === "explain" || section === "config") && !expanded);
  const selectedIndex = () =>
    Math.max(
      0,
      items.findIndex(
        (item) => item.value === (sectionMenu ? menuSection : selected),
      ),
    );
  const switchSection = (next: InspectorSection) => {
    section = next;
    selected = "";
    selectedSegment = undefined;
    expanded = false;
    sectionMenu = false;
    viewport.reset();
    if (next === "usage") {
      sources.enterUsage();
    }
  };
  const rows = (): InspectorRow[] => {
    if (sectionMenu) {
      return INSPECTOR_SECTIONS.map((id) => ({
        value: id,
        label: id,
        description: DESCRIPTIONS[id],
      }));
    }
    if (section === "config") {
      return [
        {
          value: "effective",
          label: "Effective configuration",
          description: "Provenance, repeated placements and supported fields",
        },
        ...PRESET_IDS.map((preset) => ({
          value: preset,
          label: preset,
          description: "Browse JSON and passive preview, never apply",
        })),
      ];
    }
    if (section !== "explain") {
      return [];
    }
    const frame = sources.frame();
    const placed =
      frame?.decisions.flatMap((decision) => {
        if (!hidden && !decision.display) {
          return [];
        }
        return [
          {
            value: `${decision.region}:${decision.id}:${decision.child}`,
            segment: decision.id,
            label: `${SEGMENTS[decision.id].title} · ${decision.region}`,
            description: decision.display
              ? `${text(decision.display, 120)} · ${decision.decision}`
              : decision.reason,
          },
        ];
      }) ?? [];
    if (!hidden) {
      return placed;
    }
    return [
      ...placed,
      ...(frame?.disabled ?? SEGMENT_IDS).map((id) => ({
        value: id,
        segment: id,
        label: SEGMENTS[id].title,
        description: "Disabled by configuration",
      })),
    ];
  };
  const lines = (): string[] => {
    const state = snapshot();
    if (!state) {
      return [];
    }
    if (section === "help") {
      return HELP_LINES;
    }
    if (section === "config") {
      const preset = PRESET_IDS.find((id) => id === selected);
      if (!preset) {
        return configurationLines(sources.settings());
      }
      const preview = sources.preview(preset);
      const result = [
        ...presetLines(preset),
        "Preview uses current observed data and last editor budgets; it is not a completed render.",
      ];
      if (!preview) {
        return [...result, "No editor budget available for a preview."];
      }
      return [
        ...result,
        `Preview top (${preview.top.width} columns): ${text(preview.top.text, 4096)}`,
        `Preview bottom (${preview.bottom.width} columns): ${text(preview.bottom.text, 4096)}`,
      ];
    }
    if (section === "explain") {
      if (selectedSegment === undefined) {
        return frameSummary(sources.frame());
      }

      return explainSegment(sources.frame(), selectedSegment);
    }
    return [
      "Live domain details, not the values of an earlier captured render.",
      ...detailsLines(state, section),
    ];
  };
  const detail = (width: number) =>
    viewport.render(
      lines().flatMap((line) =>
        line.split("\n").map((part) => text(part, 4096)),
      ),
      width,
      height,
      () => tui.requestRender(),
    );
  const moveList = (action: Action) => {
    let index = selectedIndex();
    if (action === "tui.select.up") {
      index--;
    }
    if (action === "tui.select.down") {
      index++;
    }
    if (action === "tui.select.pageUp") {
      index -= listCapacity;
    }
    if (action === "tui.select.pageDown") {
      index += listCapacity;
    }
    index = Math.max(0, Math.min(items.length - 1, index));
    const value = items[index]?.value ?? "";
    if (sectionMenu) {
      menuSection = INSPECTOR_SECTIONS.find((id) => id === value) ?? section;
      if (action === "tui.select.confirm") {
        switchSection(menuSection);
      }
      return;
    }
    if (selected !== value) {
      viewport.reset();
    }
    selected = value;
    selectedSegment = items[index]?.segment;
    if (action === "tui.select.confirm") {
      expanded = true;
      viewport.reset();
    }
  };
  const handleAction = (action: Action) => {
    if (action === "tui.select.cancel") {
      if (sectionMenu) {
        sectionMenu = false;
      } else if (expanded) {
        expanded = false;
        viewport.reset();
      } else {
        done();
      }
      return;
    }
    if (action === "tui.input.tab") {
      const index = INSPECTOR_SECTIONS.indexOf(section);
      switchSection(
        INSPECTOR_SECTIONS[(index + 1) % INSPECTOR_SECTIONS.length] ??
          "explain",
      );
      return;
    }
    if (listMode()) {
      moveList(action);
      return;
    }
    if (action === "tui.select.up") {
      viewport.move(-1);
    }
    if (action === "tui.select.down") {
      viewport.move(1);
    }
    if (action === "tui.select.pageUp") {
      viewport.move(-height);
    }
    if (action === "tui.select.pageDown") {
      viewport.move(height);
    }
  };
  return {
    render(width) {
      const terminalRows = Math.max(0, Math.floor(tui.terminal.rows));
      if (width <= 0 || terminalRows === 0) {
        return [];
      }
      height = Math.max(0, terminalRows - 3);
      if (terminalRows >= 6) {
        height = terminalRows - 5;
      }
      items = rows();
      if (
        !expanded &&
        !sectionMenu &&
        !items.some((item) => item.value === selected) &&
        items[0]
      ) {
        selected = items[0].value;
        selectedSegment = items[0].segment;
      }
      const sideBySide = listMode() && width >= 110 && !sectionMenu;
      const header =
        section === "explain" && !sectionMenu && !sideBySide
          ? frameSummary(sources.frame()).slice(
              0,
              Math.min(2, Math.max(0, height - 2)),
            )
          : [];
      listCapacity = height === 0 ? 0 : Math.max(1, height - header.length - 1);
      const paint = (role: Parameters<typeof theme.fg>[0]) => (value: string) =>
        theme.fg(role, value);
      const list = new SelectList(items, Math.max(1, listCapacity), {
        selectedPrefix: paint("accent"),
        selectedText: paint("accent"),
        description: paint("muted"),
        scrollInfo: paint("dim"),
        noMatch: paint("dim"),
      });
      list.setSelectedIndex(selectedIndex());
      let content: string[];
      if (sideBySide) {
        const columns = Math.min(48, Math.floor(width / 3));
        const left = list.render(columns);
        const right = detail(width - columns - 3);
        content = Array.from(
          { length: Math.min(height, Math.max(left.length, right.length)) },
          (_, i) => {
            const label = left[i] ?? "";
            return (
              label +
              " ".repeat(Math.max(0, columns - visibleWidth(label))) +
              theme.fg("border", " │ ") +
              (right[i] ?? "")
            );
          },
        );
      } else if (listMode()) {
        content = [...header, ...list.render(width)].slice(0, height);
      } else {
        content = height > 0 ? detail(width) : [];
      }
      const itemPosition = items.length === 0 ? 0 : selectedIndex() + 1;
      const position = listMode()
        ? `${itemPosition}/${items.length}`
        : `${viewport.offset + 1}–${Math.min(viewport.total, viewport.offset + height)}/${viewport.total}`;
      const hints = [position];
      if (sectionsKey !== undefined) {
        hints.push(`${sectionsKey} sections`);
      }
      if (key("tui.input.tab")) {
        hints.push(`${key("tui.input.tab")} next`);
      }
      hints.push(
        `${key("tui.select.confirm")} details`,
        `${key("tui.select.cancel")} ${expanded || sectionMenu ? "back" : "close"}`,
      );
      let navigation = `${key("tui.select.up")}/${key("tui.select.down")} navigate · ${key("tui.select.pageUp")}/${key("tui.select.pageDown")} page`;
      if (section === "explain" && hiddenKey !== undefined) {
        navigation += ` · ${hiddenKey} hidden ${hidden ? "on" : "off"}`;
      }
      const title = truncateToWidth(
        theme.fg("accent", `Footer: ${section} · ${DESCRIPTIONS[section]}`),
        width,
        "…",
      );
      const positionHint = truncateToWidth(
        theme.fg("dim", hints.join(" · ")),
        width,
        "…",
      );
      if (terminalRows === 1) {
        return [title];
      }
      if (terminalRows === 2) {
        return [title, positionHint];
      }
      return [
        title,
        ...content,
        positionHint,
        truncateToWidth(theme.fg("dim", navigation), width, "…"),
      ];
    },
    invalidate() {},
    handleInput(input) {
      const action = ACTIONS.find((id) => keys.matches(input, id));
      if (action) {
        handleAction(action);
      } else if (sectionsKey !== undefined && matchesKey(input, sectionsKey)) {
        sectionMenu = !sectionMenu;
        menuSection = section;
      } else if (
        section === "explain" &&
        hiddenKey !== undefined &&
        matchesKey(input, hiddenKey)
      ) {
        hidden = !hidden;
      }
      tui.requestRender();
    },
    dispose() {},
  };
}
