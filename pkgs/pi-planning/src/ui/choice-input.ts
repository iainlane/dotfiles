import {
  CURSOR_MARKER,
  Editor,
  getKeybindings,
  ScrollView,
  SelectList,
  Text,
  VStack,
  type Component,
  type EditorTheme,
  type TUI,
  type TuiMouseEvent,
  type TuiMouseEventResult,
} from "@earendil-works/pi-tui";

export interface InputChoice<T extends string> {
  value: T;
  label: string;
  kind: "action" | "input";
}

export interface ChoiceInputOptions<T extends string> {
  rows: readonly InputChoice<T>[];
  theme: EditorTheme;
  onSelect(value: T, text: string): void;
  onCancel(): void;
  onInput?(data: string): boolean;
  disabled?(): boolean;
  hasAdditionalInput?(): boolean;
  additionalContent?: Component;
  reservedRows?: number;
}

interface EditorHandlers {
  input(data: string): void;
  focus(): void;
  disabled(): boolean;
}

class ChoiceEditor extends Editor {
  private readonly handlers: EditorHandlers;

  constructor(tui: TUI, theme: EditorTheme, handlers: EditorHandlers) {
    super(tui, theme);
    this.handlers = handlers;
  }

  override handleInput(data: string): void {
    this.handlers.input(data);
  }

  handleEditingInput(data: string): void {
    super.handleInput(data);
  }

  override handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (this.handlers.disabled()) {
      return undefined;
    }
    const result = super.handleMouse(event);
    if (result?.focus === true) {
      this.handlers.focus();
    }
    return result;
  }
}

class CursorScroll extends ScrollView {
  private followCaret = true;
  private width = 1;
  private maximumHeight = 5;
  private readonly content: Component;
  private readonly requestRender: () => void;

  constructor(content: Component, requestRender: () => void) {
    super(content, { overscroll: "contain", scrollbar: "auto" });
    this.content = content;
    this.requestRender = requestRender;
  }

  followCursor(): void {
    this.followCaret = true;
  }

  limit(height: number): void {
    this.maximumHeight = height;
  }

  override render(width: number): string[] {
    if (this.width !== width) {
      this.followCaret = true;
    }
    this.width = width;
    const contentHeight = this.content.render(
      this.getContentWidth(width),
    ).length;
    this.updateLayout(
      contentHeight,
      Math.min(contentHeight, this.maximumHeight),
      this.requestRender,
    );
    return super
      .render(width)
      .slice(this.scrollTop, this.scrollTop + this.viewportHeight);
  }

  override handleMouse(
    event: TuiMouseEvent,
  ): ReturnType<ScrollView["handleMouse"]> {
    if (
      event.type === "wheel" ||
      event.y < 0 ||
      event.y >= this.viewportHeight
    ) {
      return undefined;
    }
    return super.handleMouse({
      ...event,
      y: event.y + this.scrollTop,
      height: this.content.render(this.getContentWidth(event.width)).length,
    });
  }

  override updateLayout(
    contentHeight: number,
    viewportHeight: number,
    requestRender: () => void,
  ): void {
    const resized = this.viewportHeight !== viewportHeight;
    super.updateLayout(contentHeight, viewportHeight, requestRender);
    if ((!this.followCaret && !resized) || viewportHeight < 1) {
      return;
    }
    this.followCaret = false;
    const cursor = this.content
      .render(this.getContentWidth(this.width))
      .findIndex((line) => line.includes(CURSOR_MARKER));
    if (cursor < 0) {
      return;
    }
    if (cursor < this.scrollTop) {
      this.scrollTo(cursor);
      return;
    }
    if (cursor >= this.scrollTop + viewportHeight) {
      this.scrollTo(cursor - viewportHeight + 1);
    }
  }
}

class ChoiceLine implements Component {
  private readonly list: SelectList;
  private readonly index: number;
  private readonly focus: () => void;
  private readonly disabled: () => boolean;

  constructor(
    list: SelectList,
    index: number,
    focus: () => void,
    disabled: () => boolean,
  ) {
    this.list = list;
    this.index = index;
    this.focus = focus;
    this.disabled = disabled;
  }

  render(width: number): string[] {
    return [this.list.render(width)[this.index] ?? ""];
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (
      this.disabled() ||
      event.button !== "left" ||
      (event.type !== "press" && event.type !== "click")
    ) {
      return undefined;
    }
    this.focus();
    return this.list.handleMouse({ ...event, y: this.index });
  }

  invalidate(): void {
    this.list.invalidate();
  }
}

class EditableChoice extends VStack {
  private readonly body: CursorScroll;

  constructor(
    header: Component,
    body: CursorScroll,
    notice: Component,
    visible: () => boolean,
  ) {
    super([
      { component: header, minSize: 1, shrink: 0 },
      { component: body, minSize: 1, maxSize: 5, visible },
      notice,
    ]);
    this.body = body;
  }

  limit(height: number): void {
    this.body.limit(height);
    const body = this.entries[1];
    if (body) {
      body.maxSize = height;
    }
  }
}

export class ChoiceInput<T extends string> extends VStack {
  private readonly list: SelectList;
  private readonly editor: ChoiceEditor;
  private readonly scroll: CursorScroll;
  private readonly inputRow: EditableChoice;
  private readonly inputIndex: number;
  private readonly notice = new Text("", 0, 0);
  private inputFocus = false;
  private hasFocus = false;
  private readonly tui: TUI;
  private readonly options: ChoiceInputOptions<T>;

  constructor(tui: TUI, options: ChoiceInputOptions<T>) {
    super();
    this.tui = tui;
    this.options = options;
    const inputs = options.rows.filter((row) => row.kind === "input");
    if (
      inputs.length !== 1 ||
      new Set(options.rows.map((row) => row.value)).size !== options.rows.length
    ) {
      throw new Error(
        "An editable choice list requires unique values and one input row.",
      );
    }
    this.inputIndex = options.rows.findIndex((row) => row.kind === "input");
    this.list = new SelectList(
      [...options.rows],
      options.rows.length,
      options.theme.selectList,
    );
    this.editor = new ChoiceEditor(tui, options.theme, {
      input: (data) => this.handleInput(data),
      focus: () => this.focusInput(),
      disabled: () => options.disabled?.() === true,
    });
    const content = new VStack([
      this.editor,
      ...(options.additionalContent ? [options.additionalContent] : []),
    ]);
    this.scroll = new CursorScroll(content, () => tui.requestRender());
    const header = this.choiceLine(this.inputIndex);
    this.inputRow = new EditableChoice(
      header,
      this.scroll,
      this.notice,
      () =>
        this.inputFocus ||
        this.list.getSelectedItem()?.value === inputs[0]?.value ||
        this.text.length > 0 ||
        options.hasAdditionalInput?.() === true,
    );
    for (const [index, row] of options.rows.entries()) {
      this.addChild(
        row.kind === "input" ? this.inputRow : this.choiceLine(index),
        { shrink: 0, minSize: 1 },
      );
    }
    this.list.onSelect = (item) => this.choose(item.value);
    this.list.onCancel = () => options.onCancel();
    this.list.onSelectionChange = () => tui.requestRender();
    this.editor.onSubmit = (text) => {
      this.editor.setText(text);
      this.choose(options.rows[this.inputIndex]?.value);
    };
    this.editor.onChange = () => {
      this.notice.setText("");
      this.scroll.followCursor();
      tui.requestRender();
    };
  }

  get focused(): boolean {
    return this.hasFocus;
  }

  set focused(value: boolean) {
    this.hasFocus = value;
    this.editor.focused = value && this.inputFocus;
  }

  get text(): string {
    return this.editor.getExpandedText();
  }

  focusInput(): void {
    this.inputFocus = true;
    this.list.setSelectedIndex(this.inputIndex);
    this.editor.focused = this.hasFocus;
    this.scroll.followCursor();
    this.tui.requestRender();
  }

  private focusChoices(): void {
    this.inputFocus = false;
    this.editor.focused = false;
    this.tui.requestRender();
  }

  private choiceLine(index: number): ChoiceLine {
    return new ChoiceLine(
      this.list,
      index,
      () => this.focusChoices(),
      () => this.options.disabled?.() === true,
    );
  }

  private choose(value: string | undefined): void {
    const row = this.options.rows.find(
      (candidate) => candidate.value === value,
    );
    if (!row || this.options.disabled?.() === true) {
      return;
    }
    if (
      row.kind === "input" &&
      this.text.trim() === "" &&
      this.options.hasAdditionalInput?.() !== true
    ) {
      this.notice.setText("Write feedback before requesting revisions.");
      this.focusInput();
      return;
    }
    this.options.onSelect(row.value, this.text);
  }

  override render(width: number): string[] {
    this.inputRow.limit(
      Math.max(
        1,
        Math.min(
          5,
          this.tui.terminal.rows -
            this.options.rows.length -
            (this.options.reservedRows ?? 6),
        ),
      ),
    );
    return super.render(width);
  }

  handleInput(data: string): void {
    if (
      this.options.disabled?.() === true ||
      this.options.onInput?.(data) === true
    ) {
      return;
    }
    const keys = getKeybindings();
    if (keys.matches(data, "tui.input.tab")) {
      if (this.inputFocus) {
        this.focusChoices();
        return;
      }
      this.focusInput();
      return;
    }
    if (this.inputFocus) {
      if (keys.matches(data, "tui.select.cancel")) {
        this.focusChoices();
        return;
      }
      this.scroll.followCursor();
      this.editor.handleEditingInput(data);
      return;
    }
    this.list.handleInput(data);
  }
}
