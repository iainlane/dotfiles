import { homedir } from "node:os";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { readGit } from "./git.ts";
import type { FooterRuntime } from "./runtime.ts";

export const nodeRuntime: FooterRuntime = {
  homeDirectory: homedir(),
  get settingsPath() {
    return join(getAgentDir(), "session-footer.json");
  },
  readSettings(): string | undefined {
    try {
      return readFileSync(this.settingsPath, "utf8");
    } catch (error) {
      if (
        error instanceof Error &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        return undefined;
      }
      throw error;
    }
  },
  clock: {
    now: Date.now,
    after(milliseconds, callback) {
      const timer = setTimeout(callback, milliseconds);
      return () => clearTimeout(timer);
    },
    every(milliseconds, callback) {
      const timer = setInterval(callback, milliseconds);
      return () => clearInterval(timer);
    },
  },
  requestId: randomUUID,
  readGit,
  reportError(error) {
    console.error("session-footer: background refresh failed", error);
  },
};
