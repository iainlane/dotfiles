// Pi's SDK types are unavailable in this standalone extension.
interface ExtensionAPI {
  events: {
    on(event: string, listener: (message: unknown) => void): unknown;
    emit(event: string, message: unknown): void;
  };
}

const WIDGET_ID = "quota";
const FOOTER_UPDATE_EVENT = "pi-footer:update-widget";
const SUB_CORE_EVENTS = ["sub-core:ready", "sub-core:update-current"];

interface RateWindow {
  label?: unknown;
  usedPercent?: unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function readWindows(message: unknown): RateWindow[] {
  if (!isRecord(message) || !isRecord(message.state)) return [];

  const usage = message.state.usage;
  if (!isRecord(usage) || !Array.isArray(usage.windows)) return [];

  return usage.windows.filter(isRecord);
}

function format(windows: RateWindow[]): string {
  return windows
    .filter(
      (window) =>
        typeof window.label === "string" &&
        typeof window.usedPercent === "number",
    )
    .map(
      (window) =>
        `${window.label} ${Math.round(window.usedPercent as number)}%`,
    )
    .join(" ");
}

export default function (pi: ExtensionAPI) {
  for (const event of SUB_CORE_EVENTS) {
    pi.events.on(event, (message: unknown) => {
      const value = format(readWindows(message));

      // pi-footer requires null to clear the widget.
      pi.events.emit(FOOTER_UPDATE_EVENT, {
        widgetId: WIDGET_ID,
        value: value === "" ? null : value,
      });
    });
  }
}
