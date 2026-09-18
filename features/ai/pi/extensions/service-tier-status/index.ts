// pi-service-tier publishes through the pi-fancy-footer protocol, even when
// pi-fancy-footer is not installed.

// Pi's SDK types are unavailable in this standalone extension.
interface ExtensionAPI {
  events: {
    on(event: string, listener: (message: unknown) => void): unknown;
    emit(event: string, message: unknown): void;
  };
}

const SERVICE_TIER_WIDGET_ID = "pi-service-tier.service-tier";
const FANCY_FOOTER_PROTOCOL = 1;
const FANCY_FOOTER_WIDGET_EVENT = "pi-fancy-footer:widget";
const FANCY_FOOTER_READY_EVENT = "pi-fancy-footer:ready";

const WIDGET_ID = "service-tier";
const FOOTER_UPDATE_EVENT = "pi-footer:update-widget";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function readText(message: unknown): string | null {
  if (!isRecord(message) || message.protocol !== FANCY_FOOTER_PROTOCOL)
    return null;

  const widget = message.widget;
  if (!isRecord(widget) || widget.id !== SERVICE_TIER_WIDGET_ID) return null;

  const content = widget.content;
  if (!isRecord(content) || typeof content.text !== "string") return null;

  return content.text;
}

export default function (pi: ExtensionAPI) {
  pi.events.on(FANCY_FOOTER_WIDGET_EVENT, (message: unknown) => {
    const text = readText(message);
    if (text === null) return;

    pi.events.emit(FOOTER_UPDATE_EVENT, {
      widgetId: WIDGET_ID,
      value: text === "" ? null : text,
    });
  });

  // Request the current state in case pi-service-tier loaded first.
  pi.events.emit(FANCY_FOOTER_READY_EVENT, { protocol: FANCY_FOOTER_PROTOCOL });
}
