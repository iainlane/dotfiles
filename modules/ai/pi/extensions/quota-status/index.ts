// Put the subscription quota in the footer.
//
// `@marckrenn/pi-sub-core` fetches and caches usage but renders nothing of its
// own. It announces each refresh on pi's event bus, and `pi-footer` renders
// whatever an extension publishes to a widget id. This joins the two.
//
// The `sub-core:ready` event covers pi-sub-core loading first, and
// `sub-core:update-current` carries every later refresh.

// Pi passes the extension API in. Only the event bus is used here, and these
// files live outside any npm project, so describe that much structurally
// rather than importing types this directory cannot resolve.
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

// The windows come off the event bus untyped, so read them defensively: a
// shape change upstream should blank the widget, not throw inside the footer.
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

      // A null value clears the widget, which is what an empty read means:
      // pi-sub-core has no usage to show for the current provider.
      pi.events.emit(FOOTER_UPDATE_EVENT, {
        widgetId: WIDGET_ID,
        value: value === "" ? null : value,
      });
    });
  }
}
