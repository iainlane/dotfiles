import { homedir } from "node:os";
import { isAbsolute, relative, sep } from "node:path";

const unsafeRanges: readonly (readonly [number, number])[] = [
  [0x0000, 0x0008],
  [0x000b, 0x001f],
  [0x007f, 0x009f],
  [0x061c, 0x061c],
  [0x200e, 0x200f],
  [0x202a, 0x202e],
  [0x2066, 0x2069],
];

export function displayText(
  value: string,
  layout: "document" | "inline" = "document",
): string {
  return Array.from(value, (character) => {
    const code = character.codePointAt(0);
    const layoutControl =
      layout === "inline" && (code === 0x0009 || code === 0x000a);
    return code !== undefined &&
      (layoutControl ||
        unsafeRanges.some(([start, end]) => code >= start && code <= end))
      ? `\\u${code.toString(16).padStart(4, "0")}`
      : character;
  }).join("");
}

export function displayPath(value: string): string {
  if (!isAbsolute(value)) {
    return displayText(value, "inline");
  }
  const local = relative(homedir(), value);
  if (local === ".." || local.startsWith(`..${sep}`) || isAbsolute(local)) {
    return displayText(value, "inline");
  }
  return displayText(local === "" ? "~" : `~${sep}${local}`, "inline");
}

export function displayStoredMetadata(value: unknown): string {
  try {
    return displayText(JSON.stringify(value, null, 2) ?? "undefined");
  } catch {
    return "Raw metadata could not be serialised.";
  }
}
