import { expect, it, vi } from "vitest";
import { resizeImage, SettingsManager } from "@earendil-works/pi-coding-agent";
import { ClipboardFeedbackError, readClipboardImage } from "../src/feedback.ts";
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

it.each([true, false])(
  "uses native encoded-image limits and respects auto-resizing: %s",
  async (autoResize) => {
    const bytes = Buffer.concat([
      Buffer.from(feedbackImage.data, "base64"),
      Buffer.alloc(6_000_000),
    ]);
    const result = readClipboardImage(
      { getImage: async () => bytes },
      SettingsManager.inMemory({ images: { autoResize } }),
    ).then(
      (image) => ({ image }),
      (error: unknown) => ({ error: String(error) }),
    );
    const prepared = await resizeImage(bytes, "image/png");
    if (prepared === null) {
      throw new Error(
        "Expected the native processor to prepare the valid image fixture",
      );
    }
    expect(await result).toStrictEqual(
      autoResize
        ? {
            image: {
              type: "image",
              data: prepared.data,
              mimeType: prepared.mimeType,
            },
          }
        : {
            error:
              "ClipboardFeedbackError: The image exceeds Pi's native image limits. Enable image auto-resizing or use a smaller image.",
          },
    );
  },
);

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
