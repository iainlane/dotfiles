import { mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { onTestFinished } from "vitest";

/** The time at which the clock fixture starts. */
export const clockStart = Date.UTC(2026, 9, 20, 12);

/** The extension that runs the session footer on the fixture clock. */
export const clockedFooter = fileURLToPath(
  new URL(import.meta.resolve("#test/fixtures/footer.ts")),
);

/**
 * The environment that gives the clock fixture its file, and a setter for the
 * clock's time.
 */
export interface FixtureClock {
  env: { PI_FOOTER_CLOCK: string };
  /** Moves the fixture clock to `time`, which must not be earlier. */
  set(time: number): void;
}

/** Creates the clock fixture's file, set to `clockStart`. */
export function fixtureClock(): FixtureClock {
  const directory = mkdtempSync(join(tmpdir(), "pi-footer-clock-"));
  const path = join(directory, "now");
  const set = (time: number) => {
    const next = join(directory, "next");

    writeFileSync(next, String(time));
    renameSync(next, path);
  };

  onTestFinished(() => rmSync(directory, { recursive: true, force: true }));
  set(clockStart);

  return { env: { PI_FOOTER_CLOCK: path }, set };
}
