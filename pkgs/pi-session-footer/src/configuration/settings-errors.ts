/**
 * A settings document failed validation. `field` is the path of the rejected
 * value, such as `top-left[1].roles.staged.colour`, and `problem` describes
 * the failure without that path.
 */
export abstract class SettingsError extends Error {
  protected constructor(
    readonly field: string,
    readonly problem: string,
  ) {
    super(`${field}: ${problem}`);
    this.name = new.target.name;
  }
}

export class ExpectedObjectError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected an object");
  }
}

export class UnknownSettingError extends SettingsError {
  constructor(field: string) {
    super(field, "Unknown setting");
  }
}

export class InvalidColourError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected a foreground theme colour or #RRGGBB");
  }
}

export class InvalidInlineTextError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected safe inline text of one to eight columns");
  }
}

export class InlineTextTooWideError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected at most 8 columns");
  }
}

export class SymbolTextAndAliasError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected text or alias, not both");
  }
}

export class UnknownSymbolAliasError extends SettingsError {
  constructor(field: string) {
    super(field, "Unknown symbol alias");
  }
}

export class SymbolNotAllowedError extends SettingsError {
  constructor(field: string) {
    super(field, "This part has no decorative symbol");
  }
}

export class UnknownWidgetPartError extends SettingsError {
  constructor(field: string) {
    super(field, "Unknown widget part");
  }
}

export class TextColourNotAllowedError extends SettingsError {
  constructor(field: string) {
    super(field, "This part has no text");
  }
}

export class MultiColumnSymbolError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected a single-column symbol");
  }
}

export class InvalidPlacementError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected a built-in widget ID or object");
  }
}

export class UnknownWidgetError extends SettingsError {
  constructor(field: string) {
    super(field, "Unknown widget");
  }
}

export class UnknownPresetError extends SettingsError {
  constructor() {
    super("preset", "Unknown preset");
  }
}

export class ExpectedWidgetArrayError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected an array of widgets");
  }
}

export class DuplicateWidgetError extends SettingsError {
  constructor(field: string) {
    super(field, "Expected distinct widget IDs");
  }
}

export class InvalidPersistenceError extends SettingsError {
  constructor() {
    super("persistence", "Expected local or session");
  }
}
