import {
  Text,
  matchesKey,
  truncateToWidth,
  type KeyId,
} from "@earendil-works/pi-tui";
import type { FooterRoute } from "#footer/application/commands.ts";
import { InspectionPages } from "./inspection-pages.ts";
import {
  INSPECTOR_SECTIONS,
  type InspectionNavigation,
  type InspectionPage,
  type InspectionRow,
  type InspectorSection,
} from "./inspection-page.ts";
import type { InspectorContext, InspectorSources } from "./inspector.ts";
import { CapturedFooter } from "./explanation.ts";
import { SelectionViewport } from "#footer/ui/shared/selection-viewport.ts";
import type { SegmentId } from "#footer/configuration/settings.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";
import { DetailViewport } from "#footer/ui/shared/viewport.ts";

export {
  INSPECTOR_SECTIONS,
  type InspectorSection,
} from "./inspection-page.ts";
type ViewFactory = Parameters<InspectorContext["ui"]["custom"]>[0];
type ViewEnvironment = {
  tui: Parameters<ViewFactory>[0];
  theme: Parameters<ViewFactory>[1];
  keys: Parameters<ViewFactory>[2];
};
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
type Movement = "up" | "down" | "pageUp" | "pageDown";
const MOVEMENTS = new Map<Action, Movement>([
  ["tui.select.up", "up"],
  ["tui.select.down", "down"],
  ["tui.select.pageUp", "pageUp"],
  ["tui.select.pageDown", "pageDown"],
]);
interface PageState {
  page: InspectionPage;
  list: SelectionViewport;
  detail: DetailViewport;
  rows: InspectionRow[];
}
function pageState(page: InspectionPage): PageState {
  return {
    page,
    list: new SelectionViewport(),
    detail: new DetailViewport(),
    rows: [],
  };
}
class InspectorView implements InspectionNavigation {
  private readonly pages: InspectionPages;
  private readonly saved = new Map<InspectorSection, PageState[]>();
  private stack: PageState[] = [];
  private activeSection: InspectorSection = "explain";
  private captured: CapturedFooter | undefined;
  private closed = false;
  private width = 80;
  private height = 0;
  private readonly sectionsKey: KeyId | undefined;
  constructor(
    private readonly environment: ViewEnvironment,
    route: FooterRoute,
    private readonly data: {
      snapshot(): FooterSnapshot | undefined;
      sources: InspectorSources;
    },
    private readonly done: (next?: "customise") => void,
  ) {
    this.sectionsKey = (["s", "alt+s"] as const).find(
      (binding) =>
        !ACTIONS.some((action) =>
          environment.keys.getKeys(action).includes(binding),
        ),
    );
    this.pages = new InspectionPages(
      () => {
        this.captured ??= new CapturedFooter(data.sources.frame());
        return this.captured;
      },
      () => data.snapshot(),
      this,
    );
    this.section(route.view === "help" ? "help" : "explain");
    if (route.view === "explain" && route.segment !== undefined) {
      this.widget(route.segment);
    }
  }
  private get current(): PageState {
    const value = this.stack.at(-1);
    if (!value) {
      throw new Error("The inspector has no current page");
    }
    return value;
  }
  private key(action: Action): string {
    return this.environment.keys
      .getKeys(action)
      .filter(
        (binding) =>
          ACTIONS.find((candidate) =>
            this.environment.keys.getKeys(candidate).includes(binding),
          ) === action,
      )
      .join("/");
  }
  open(page: InspectionPage): void {
    this.stack.push(pageState(page));
  }
  section(section: InspectorSection): void {
    if (this.stack.at(-1)?.page.title === "Sections") {
      this.stack.pop();
    }
    if (section !== this.activeSection && section === "usage") {
      this.data.sources.enterUsage();
    }
    this.activeSection = section;
    let stack = this.saved.get(section);
    if (stack === undefined) {
      stack = [pageState(this.pages.section(section))];
      this.saved.set(section, stack);
    }
    this.stack = stack;
  }
  widget(id: SegmentId): void {
    if (this.activeSection === "explain" && this.stack.length === 1) {
      const root = this.current;
      const entries = this.captured?.entries ?? [];
      if (
        entries.find((entry) => entry.key === root.list.selected)?.id !== id
      ) {
        const placement = entries.find((entry) => entry.id === id);
        if (placement !== undefined) {
          root.list.select(placement.key);
        }
      }
    }
    this.open(this.pages.widget(id));
  }
  sections(): void {
    if (this.current.page.title === "Sections") {
      this.back();
      return;
    }
    this.open(this.pages.sections());
  }
  customise(): void {
    this.closed = true;
    this.done("customise");
  }
  private back(): void {
    if (this.stack.length > 1) {
      this.stack.pop();
      return;
    }
    this.closed = true;
    this.done();
  }
  private content(width: number): string[] {
    const state = this.current;
    const { theme, tui } = this.environment;
    if (this.height === 0) {
      return [];
    }
    if (state.page.kind === "detail") {
      return state.detail.render(state.page.lines(), width, this.height, () =>
        tui.requestRender(),
      );
    }
    const content = state.page.content();
    state.rows = content.rows;
    const summary = [
      ...content.summary.filter((line) => line.colour !== undefined),
      ...content.summary.filter((line) => line.colour === undefined),
    ].flatMap((line) =>
      new Text(
        line.colour === undefined
          ? line.value
          : theme.fg(line.colour, line.value),
        0,
        0,
      ).render(width),
    );
    const introduction = summary.slice(
      0,
      Math.max(0, this.height - Math.min(3, this.height)),
    );
    const rows = state.list.render(
      content.rows.map((row) => ({
        key: row.key,
        value:
          row.colour === undefined
            ? row.value
            : theme.fg(row.colour, row.value),
        description: row.description,
      })),
      width,
      this.height - introduction.length,
      theme,
      () => tui.requestRender(),
    );
    return [...introduction, ...rows];
  }
  render(width: number): string[] {
    if (this.closed) {
      return [];
    }
    this.width = width;
    const rows = Math.max(0, this.environment.tui.terminal.rows);
    if (width <= 0 || rows === 0) {
      return [];
    }
    this.height = Math.max(0, rows - (rows >= 4 ? 3 : 2));
    const theme = this.environment.theme;
    const title = theme.fg("accent", `Footer › ${this.current.page.title}`);
    const content = this.content(width);
    const confirm = this.key("tui.select.confirm");
    const cancel = this.key("tui.select.cancel");
    const hints: string[] = [];
    if (this.current.page.kind === "menu" && confirm !== "") {
      hints.push(`${confirm} open`);
    }
    if (cancel !== "") {
      hints.push(`${cancel} ${this.stack.length > 1 ? "back" : "close"}`);
    }
    if (this.sectionsKey !== undefined) {
      hints.push(`${this.sectionsKey} sections`);
    }
    const state = this.current;
    const position =
      state.page.kind === "menu"
        ? `${state.list.position.current}/${state.list.position.total}`
        : `${state.detail.total === 0 ? 0 : state.detail.offset + 1}–${Math.min(state.detail.total, state.detail.offset + state.detail.height)}/${state.detail.total}`;
    const lines = [title, ...content];
    if (rows >= 2) {
      lines.push(theme.fg("dim", hints.join(" · ")));
    }
    if (rows >= 4) {
      lines.push(
        theme.fg(
          "dim",
          `${position} · ${this.key("tui.select.up")}/${this.key("tui.select.down")} move · ${this.key("tui.select.pageUp")}/${this.key("tui.select.pageDown")} page`,
        ),
      );
    }
    return lines
      .slice(0, rows)
      .map((line) => truncateToWidth(line, width, "…"));
  }
  private act(action: Action | undefined, input: string): void {
    if (action === "tui.select.cancel") {
      this.back();
      return;
    }
    if (this.height === 0) {
      return;
    }
    if (action === "tui.input.tab") {
      this.section(
        INSPECTOR_SECTIONS[
          (INSPECTOR_SECTIONS.indexOf(this.activeSection) + 1) %
            INSPECTOR_SECTIONS.length
        ] ?? "explain",
      );
      return;
    }
    if (action === "tui.select.confirm") {
      if (this.current.page.kind === "menu") {
        this.current.rows
          .find((row) => row.key === this.current.list.selected)
          ?.run();
      }
      return;
    }
    const movement = action === undefined ? undefined : MOVEMENTS.get(action);
    if (movement !== undefined) {
      if (this.current.page.kind === "menu") {
        this.current.list.move(movement);
        return;
      }
      const offsets = {
        up: -1,
        down: 1,
        pageUp: -this.height,
        pageDown: this.height,
      };
      this.current.detail.move(offsets[movement]);
      return;
    }
    if (
      action === undefined &&
      this.sectionsKey !== undefined &&
      matchesKey(input, this.sectionsKey)
    ) {
      this.sections();
    }
  }
  handleInput(input: string): void {
    if (this.closed) {
      return;
    }
    this.render(this.width);
    this.act(
      ACTIONS.find((action) => this.environment.keys.matches(input, action)),
      input,
    );
    this.environment.tui.requestRender();
  }
  dispose(): void {
    this.closed = true;
  }
}
export function createInspectorView(
  environment: ViewEnvironment,
  route: FooterRoute,
  data: { snapshot(): FooterSnapshot | undefined; sources: InspectorSources },
  done: (next?: "customise") => void,
): ReturnType<ViewFactory> {
  const view = new InspectorView(environment, route, data, done);
  return {
    render: (width) => view.render(width),
    handleInput: (input) => view.handleInput(input),
    invalidate() {},
    dispose: () => view.dispose(),
  };
}
