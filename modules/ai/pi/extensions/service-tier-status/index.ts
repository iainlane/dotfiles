// Show the active provider service tier in the footer.
//
// `pi-service-tier` publishes its state for a different statusline extension,
// pi-fancy-footer, using that project's event name and payload. We run
// pi-footer, which reads a plain string from a widget id. This extension
// subscribes to the pi-fancy-footer event, takes the service tier out of its
// payload, and publishes that string to pi-footer's widget.
//
// pi-service-tier publishes once when it loads and again whenever it sees a
// fancy-footer `ready` event. Emitting that on startup covers the case where
// pi-service-tier loaded first and we missed its initial publish.

// Pi passes the extension API in. Only the event bus is used here, and these
// files live outside any npm project, so describe that much structurally
// rather than importing types this directory cannot resolve.
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

// Read the widget text out of pi-service-tier's payload, returning null for
// anything that is not the service-tier widget carrying text.
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

  pi.events.emit(FANCY_FOOTER_READY_EVENT, { protocol: FANCY_FOOTER_PROTOCOL });
}
