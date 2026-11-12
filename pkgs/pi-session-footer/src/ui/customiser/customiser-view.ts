import {
  Input,
  SelectList,
  fuzzyFilter,
  parseColor,
  stripTerminalSequences,
  truncateToWidth,
  type Focusable,
} from "@earendil-works/pi-tui";
import { isThemeColour } from "#footer/configuration/appearance.ts";
import { SettingsError } from "#footer/configuration/settings-errors.ts";
import type { DockView } from "#footer/ui/dock/dock-host.ts";
import type {
  CustomiserEnvironment,
  CustomiserNavigation,
  CustomiserPage,
  CustomiserRow,
} from "./customiser-page.ts";
import { DetailViewport } from "#footer/ui/shared/viewport.ts";
import { text } from "#footer/shared/text.ts";

interface PageState {
  page: CustomiserPage;
  selected: string | undefined;
  input: Input;
  list: SelectList | undefined;
  rows: CustomiserRow[];
  capacity: number;
  initialised: boolean;
  viewport: DetailViewport;
  error: string;
}
function localError(error: unknown): string {
  if (error instanceof SettingsError) {
    return error.problem;
  }
  return error instanceof Error ? error.message : "Cannot update this setting";
}
export class MenuPageExpectedError extends Error {
  constructor(readonly kind: CustomiserPage["kind"]) {
    super(`Expected a menu page, not ${kind}`);
    this.name = "MenuPageExpectedError";
  }
}
function pageState(page: CustomiserPage): PageState {
  const input = new Input();
  input.setValue(page.kind === "input" ? page.initial : "");
  return {
    page,
    input,
    selected: page.kind === "menu" ? page.selected : undefined,
    list: undefined,
    rows: [],
    capacity: 0,
    initialised: false,
    viewport: new DetailViewport(),
    error: "",
  };
}
export class CustomiserView
  implements DockView, Focusable, CustomiserNavigation
{
  readonly capturesViewportInput = true;
  private readonly stack: [PageState, ...PageState[]];
  private hasFocus = false;
  private tooSmall = false;
  private controls: readonly string[] = [];

  constructor(
    private readonly env: CustomiserEnvironment,
    createRoot: (navigation: CustomiserNavigation) => CustomiserPage,
  ) {
    this.stack = [pageState(createRoot(this))];
  }
  private get current(): PageState {
    return this.stack.at(-1) ?? this.stack[0];
  }
  get focused(): boolean {
    return this.hasFocus;
  }
  set focused(value: boolean) {
    this.hasFocus = value;
    const current = this.current;
    current.input.focused =
      value &&
      (current.page.kind === "input" ||
        (current.page.kind === "menu" && current.page.search === true));
  }
  open(page: CustomiserPage): void {
    this.current.input.focused = false;
    this.stack.push(pageState(page));
    this.focused = this.hasFocus;
    this.env.tui.requestRender();
  }
  back(): void {
    if (this.stack.length === 1) {
      this.env.transaction.cancel();
      return;
    }
    this.current.page.cancel?.();
    this.accept();
  }
  accept(): void {
    if (this.stack.length > 1) {
      this.stack.pop();
    }
    this.refresh();
    this.focused = this.hasFocus;
  }
  root(): void {
    while (this.stack.length > 1) {
      this.stack.pop();
    }
    this.refresh();
    this.focused = this.hasFocus;
  }
  refresh(): void {
    this.current.list = undefined;
    this.env.tui.requestRender();
  }
  private menu(capacity: number): SelectList {
    const state = this.current;
    const page = state.page;
    if (page.kind !== "menu") {
      throw new MenuPageExpectedError(page.kind);
    }
    if (state.list && state.capacity === capacity) {
      return state.list;
    }
    state.capacity = capacity;
    const rows = page.rows();
    state.rows =
      page.search === true
        ? fuzzyFilter(
            rows,
            state.input.getValue(),
            (row) => `${row.label} ${row.id} ${row.description ?? ""}`,
          )
        : rows;
    const theme = () => this.env.theme();
    const items = state.rows.map((row) => {
      let label = row.label;
      if (row.tint !== undefined) {
        label = isThemeColour(row.tint)
          ? theme().fg(row.tint, label)
          : theme().style(label, { fg: parseColor(row.tint) });
      }
      return { value: row.id, label, description: row.description };
    });
    const list = new SelectList(items, Math.max(1, capacity - 1), {
      selectedPrefix: (value) => theme().fg("accent", value),
      selectedText: (value) => theme().fg("accent", value),
      description: (value) => theme().fg("muted", value),
      scrollInfo: (value) => theme().fg("dim", value),
      noMatch: (value) => theme().fg("muted", value),
    });
    const previous = state.selected;
    const selected = state.rows.findIndex((row) => row.id === state.selected);
    list.setSelectedIndex(Math.max(0, selected));
    state.selected = list.getSelectedItem()?.value;
    list.onSelectionChange = (item) => this.highlight(state, item.value);
    state.list = list;
    if (!state.initialised || previous !== state.selected) {
      state.initialised = true;
      if (state.selected !== undefined) {
        this.highlight(state, state.selected);
      }
    }
    return list;
  }
  private highlight(state: PageState, id: string): void {
    state.selected = id;
    if (state.page.kind !== "menu") {
      return;
    }
    try {
      state.page.highlight?.(id);
      state.error = "";
    } catch (error) {
      state.error = localError(error);
    }
  }
  private moveMenu(data: string): void {
    const state = this.current;
    const count = state.rows.length;
    if (count === 0) {
      return;
    }
    const actions = [
      "tui.select.up",
      "tui.select.down",
      "tui.select.pageUp",
      "tui.select.pageDown",
    ] as const;
    const action = actions.find((value) => this.env.keys.matches(data, value));
    if (action === undefined) {
      return;
    }
    let index = Math.max(
      0,
      state.rows.findIndex((row) => row.id === state.selected),
    );
    const page = Math.max(1, state.capacity - 1);
    switch (action) {
      case "tui.select.up":
        index = (index + count - 1) % count;
        break;
      case "tui.select.down":
        index = (index + 1) % count;
        break;
      case "tui.select.pageUp":
        index = Math.max(0, index - page);
        break;
      case "tui.select.pageDown":
        index = Math.min(count - 1, index + page);
        break;
    }
    state.list?.setSelectedIndex(index);
    const selected = state.rows[index];
    if (selected !== undefined) {
      this.highlight(state, selected.id);
    }
  }
  render(width: number): string[] {
    const state = this.current;
    const theme = this.env.theme();
    const available = Math.max(
      2,
      Math.min(
        14,
        this.env.tui.terminal.rows - Math.max(3, this.env.composerHeight()) - 3,
      ),
    );
    const confirm = this.env.keys.getKeys("tui.select.confirm").join("/");
    const cancel = this.env.keys.getKeys("tui.select.cancel").join("/");
    const heading = theme.fg(
      "accent",
      `Footer › Customise${state.page.title === "" ? "" : ` › ${state.page.title}`}`,
    );
    this.tooSmall = available < 4 || width < 16;
    if (this.tooSmall) {
      const lines = [heading, `Resize · ${cancel} cancel`].map((line) =>
        truncateToWidth(line, width),
      );
      this.controls = lines;
      return lines;
    }
    const lines = [heading];
    let intent = "edit";
    if (state.page.kind === "input") {
      lines.push(...state.input.render(width));
      this.controls = [...lines];
      const hint = state.page.hint?.(state.input.getValue());
      if (hint !== undefined) {
        lines.push(theme.fg("muted", hint));
      }
      intent = "use";
    } else if (state.page.kind === "detail") {
      lines.push(
        ...state.viewport.render(state.page.lines(), width, available - 2, () =>
          this.env.tui.requestRender(),
        ),
      );
      this.controls = lines.slice(0, 1);
      intent = "scroll";
    } else {
      if (state.page.search === true) {
        lines.push(
          "Search: " + state.input.render(Math.max(1, width - 8)).join(""),
        );
      }
      const list = this.menu(Math.max(1, available - lines.length - 3));
      const rendered = list
        .render(width)
        .slice(0, Math.max(1, available - lines.length - 3));
      const selected = rendered.findIndex((line) =>
        stripTerminalSequences(line).startsWith("→ "),
      );
      this.controls = [
        ...lines,
        ...rendered.slice(0, Math.max(1, selected + 1)),
      ];
      lines.push(...rendered);
      intent =
        state.rows.find((row) => row.id === state.selected)?.intent ?? "edit";
    }
    if (state.error !== "") {
      lines.push(theme.fg("error", text(state.error, width)));
    }
    const transaction = this.env.transaction;
    const unsaved =
      transaction.dirty ||
      JSON.stringify(transaction.presentation) !==
        JSON.stringify(transaction.document);
    const fallback = this.env.presentationMode() === "fallback";
    if (unsaved || fallback) {
      const labels = ["Preview"];
      if (fallback) {
        labels.push("standalone footer");
      }
      if (unsaved) {
        labels.push("not saved");
      }
      lines.push(theme.fg("muted", labels.join(" · ")));
    }
    lines.push(
      theme.fg(
        "dim",
        `${confirm} ${intent} · ${cancel} ${this.stack.length === 1 ? "cancel" : "back"}`,
      ),
    );
    this.controls = this.controls.map((line) => truncateToWidth(line, width));
    return lines
      .slice(0, available)
      .map((line) => truncateToWidth(line, width));
  }
  visibleControls(): readonly string[] {
    return this.controls;
  }
  handleInput(data: string): void {
    if (this.env.transaction.closed) {
      return;
    }
    if (this.env.keys.matches(data, "tui.select.cancel")) {
      this.back();
      return;
    }
    if (this.tooSmall) {
      return;
    }
    const state = this.current;
    try {
      if (state.page.kind === "menu") {
        this.menu(Math.max(1, state.capacity));
      }
      state.error = "";
      if (state.page.kind === "input") {
        if (this.env.keys.matches(data, "tui.select.confirm")) {
          state.page.confirm(state.input.getValue());
        } else {
          const before = state.input.getValue();
          state.input.handleInput(data);
          if (state.input.getValue() !== before) {
            state.page.change(state.input.getValue());
          }
        }
      } else if (state.page.kind === "detail") {
        const page = state.viewport.height;
        if (this.env.keys.matches(data, "tui.select.up")) {
          state.viewport.move(-1);
        }
        if (this.env.keys.matches(data, "tui.select.down")) {
          state.viewport.move(1);
        }
        if (this.env.keys.matches(data, "tui.select.pageUp")) {
          state.viewport.move(-page);
        }
        if (this.env.keys.matches(data, "tui.select.pageDown")) {
          state.viewport.move(page);
        }
      } else if (this.env.keys.matches(data, "tui.select.confirm")) {
        state.rows.find((row) => row.id === state.selected)?.run();
        this.refresh();
      } else {
        const navigation = [
          "tui.select.up",
          "tui.select.down",
          "tui.select.pageUp",
          "tui.select.pageDown",
        ] as const;
        if (
          state.page.search === true &&
          !navigation.some((action) => this.env.keys.matches(data, action))
        ) {
          const before = state.input.getValue();
          state.input.handleInput(data);
          if (state.input.getValue() !== before) {
            state.selected = undefined;
            state.list = undefined;
          }
        } else {
          this.moveMenu(data);
        }
      }
    } catch (error) {
      state.error = localError(error);
    }
    this.env.tui.requestRender();
  }
  invalidate(): void {
    this.current.list = undefined;
    this.current.input.invalidate();
  }
  dispose(): void {
    this.env.transaction.cancel();
  }
}
