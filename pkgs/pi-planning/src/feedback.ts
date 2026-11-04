import type { ImageContent } from "@earendil-works/pi-ai";
import { resizeImage, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  getImageDimensions,
  type NativeClipboard,
} from "@earendil-works/pi-tui";

export class ClipboardFeedbackError extends Error {
  override readonly name = "ClipboardFeedbackError";
}

function imageMimeType(bytes: Uint8Array): string {
  const data = Buffer.from(bytes);
  if (
    data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  ) {
    return "image/png";
  }
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) {
    return "image/jpeg";
  }
  const prefix = data.subarray(0, 12).toString("ascii");
  if (prefix.startsWith("GIF87a") || prefix.startsWith("GIF89a")) {
    return "image/gif";
  }
  if (prefix.startsWith("RIFF") && prefix.slice(8, 12) === "WEBP") {
    return "image/webp";
  }
  throw new ClipboardFeedbackError(
    "Clipboard images must be PNG, JPEG, GIF or WebP.",
  );
}

export async function readClipboardImage(
  clipboard: Pick<NativeClipboard, "getImage"> | undefined,
  settings: Pick<
    SettingsManager,
    "getBlockImages" | "getImageAutoResize"
  > = SettingsManager.inMemory({}),
): Promise<ImageContent> {
  if (settings.getBlockImages()) {
    throw new ClipboardFeedbackError(
      "Image input is disabled in Pi's settings.",
    );
  }
  if (!clipboard) {
    throw new ClipboardFeedbackError(
      "Native clipboard images are unavailable on this platform. Paste text normally.",
    );
  }
  let bytes: Uint8Array | null | undefined;
  try {
    bytes = await clipboard.getImage();
  } catch (cause) {
    throw new ClipboardFeedbackError(
      "Cannot read the native clipboard image.",
      { cause },
    );
  }
  if (bytes === undefined) {
    throw new ClipboardFeedbackError(
      "Native clipboard images are unavailable on this platform. Paste text normally.",
    );
  }
  if (bytes === null) {
    throw new ClipboardFeedbackError(
      "The clipboard has no image. Paste text normally.",
    );
  }
  const mimeType = imageMimeType(bytes);
  const data = Buffer.from(bytes).toString("base64");
  try {
    const dimensions = getImageDimensions(data, mimeType);
    if (
      dimensions === null ||
      dimensions.widthPx <= 0 ||
      dimensions.heightPx <= 0
    ) {
      throw new ClipboardFeedbackError(
        "The clipboard image has invalid dimensions.",
      );
    }
  } catch (cause) {
    throw new ClipboardFeedbackError(
      "The clipboard image is invalid or incomplete.",
      { cause },
    );
  }
  let image: Awaited<ReturnType<typeof resizeImage>>;
  try {
    image = await resizeImage(bytes, mimeType);
  } catch (cause) {
    throw new ClipboardFeedbackError("Native image processing failed.", {
      cause,
    });
  }
  if (image === null) {
    throw new ClipboardFeedbackError(
      "Native image processing could not validate and prepare this image.",
    );
  }
  if (!settings.getImageAutoResize() && image.wasResized) {
    throw new ClipboardFeedbackError(
      "The image exceeds Pi's native image limits. Enable image auto-resizing or use a smaller image.",
    );
  }
  return { type: "image", mimeType: image.mimeType, data: image.data };
}
