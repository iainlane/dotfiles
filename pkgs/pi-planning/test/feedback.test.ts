import { expect, it } from "vitest";
import { resizeImage, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  ClipboardFeedbackError,
  readClipboardImage,
} from "#planning/feedback.ts";
import { feedbackImage } from "./fixtures/image.ts";

it.each([
  feedbackImage,
  {
    type: "image",
    mimeType: "image/gif",
    data: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7",
  },
])("preserves the native $mimeType image format", async (image) => {
  await expect(
    readClipboardImage({
      getImage: async () => Buffer.from(image.data, "base64"),
    }),
  ).resolves.toStrictEqual(image);
});

const unavailable = new ClipboardFeedbackError(
  "Native clipboard images are unavailable on this platform. Paste text normally.",
);
const unsupportedFormat = new ClipboardFeedbackError(
  "Clipboard images must be PNG, JPEG, GIF or WebP.",
);

it.each([
  { description: "unavailable", bytes: undefined, error: unavailable },
  {
    description: "missing",
    bytes: null,
    error: new ClipboardFeedbackError(
      "The clipboard has no image. Paste text normally.",
    ),
  },
  { description: "empty", bytes: new Uint8Array(), error: unsupportedFormat },
  {
    description: "BMP",
    bytes: Buffer.from("BMunsupported"),
    error: unsupportedFormat,
  },
  {
    description: "truncated PNG",
    bytes: Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]),
    error: new ClipboardFeedbackError(
      "The clipboard image is invalid or incomplete.",
      {
        cause: new ClipboardFeedbackError(
          "The clipboard image has invalid dimensions.",
        ),
      },
    ),
  },
])(
  "rejects unavailable, empty or unsupported clipboard images: $description",
  async ({ bytes, error }) => {
    await expect(
      readClipboardImage({ getImage: async () => bytes }),
    ).rejects.toStrictEqual(error);
  },
);

it("rejects encoded images that have valid headers but cannot be decoded", async () => {
  const data =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jPwoAAAAASUVORK5CYII=";
  await expect(
    readClipboardImage({ getImage: async () => Buffer.from(data, "base64") }),
  ).rejects.toStrictEqual(
    new ClipboardFeedbackError(
      "Native image processing could not validate and prepare this image.",
    ),
  );
});

it("honours native image blocking before reading the clipboard", async () => {
  await expect(
    readClipboardImage(
      {
        getImage: async () => {
          throw new Error("The clipboard must not be read.");
        },
      },
      SettingsManager.inMemory({ images: { blockImages: true } }),
    ),
  ).rejects.toStrictEqual(
    new ClipboardFeedbackError("Image input is disabled in Pi's settings."),
  );
});

const oversizedImage = Buffer.concat([
  Buffer.from(feedbackImage.data, "base64"),
  Buffer.alloc(6_000_000),
]);

it("uses native encoded-image limits with auto-resizing", async () => {
  const prepared = await resizeImage(oversizedImage, "image/png");
  if (prepared === null) {
    throw new Error(
      "Expected the native processor to prepare the valid image fixture",
    );
  }
  await expect(
    readClipboardImage(
      { getImage: async () => oversizedImage },
      SettingsManager.inMemory({ images: { autoResize: true } }),
    ),
  ).resolves.toStrictEqual({
    type: "image",
    data: prepared.data,
    mimeType: prepared.mimeType,
  });
});

it("refuses an image over native encoded-image limits without auto-resizing", async () => {
  await expect(
    readClipboardImage(
      { getImage: async () => oversizedImage },
      SettingsManager.inMemory({ images: { autoResize: false } }),
    ),
  ).rejects.toStrictEqual(
    new ClipboardFeedbackError(
      "The image exceeds Pi's native image limits. Enable image auto-resizing or use a smaller image.",
    ),
  );
});

it("reports unsupported native clipboard access", async () => {
  await expect(readClipboardImage(undefined)).rejects.toStrictEqual(
    unavailable,
  );
});

it("reports native clipboard transfer failures", async () => {
  await expect(
    readClipboardImage({
      getImage: async () => {
        throw new Error("Transfer failed");
      },
    }),
  ).rejects.toStrictEqual(
    new ClipboardFeedbackError("Cannot read the native clipboard image.", {
      cause: new Error("Transfer failed"),
    }),
  );
});
