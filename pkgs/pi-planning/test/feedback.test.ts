import { expect, it, vi } from "vitest";
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

it.each([
  { bytes: undefined, message: "unavailable" },
  { bytes: null, message: "no image" },
  { bytes: new Uint8Array(), message: "PNG, JPEG, GIF or WebP" },
  { bytes: Buffer.from("BMunsupported"), message: "PNG, JPEG, GIF or WebP" },
  {
    bytes: Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]),
    message: "invalid or incomplete",
  },
])(
  "rejects unavailable, empty or unsupported clipboard images: $message",
  async ({ bytes, message }) => {
    await expect(
      readClipboardImage({ getImage: async () => bytes }),
    ).rejects.toThrow(message);
  },
);

it("rejects encoded images that have valid headers but cannot be decoded", async () => {
  const data =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jPwoAAAAASUVORK5CYII=";
  await expect(
    readClipboardImage({ getImage: async () => Buffer.from(data, "base64") }),
  ).rejects.toThrow("Native image processing");
});

it("honours native image blocking before reading the clipboard", async () => {
  const getImage = vi.fn<() => Promise<Uint8Array>>(async () =>
    Buffer.from(feedbackImage.data, "base64"),
  );
  await expect(
    readClipboardImage(
      { getImage },
      SettingsManager.inMemory({ images: { blockImages: true } }),
    ),
  ).rejects.toThrow("Image input is disabled");
  expect(getImage.mock.calls).toStrictEqual([]);
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
  await expect(readClipboardImage(undefined)).rejects.toThrow(
    ClipboardFeedbackError,
  );
});

it("reports native clipboard transfer failures", async () => {
  await expect(
    readClipboardImage({
      getImage: async () => {
        throw new Error("Transfer failed");
      },
    }),
  ).rejects.toThrow("Cannot read the native clipboard image.");
});
