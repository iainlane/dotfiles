import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { readGit } from "./git.ts";
import type { FooterRuntime } from "./runtime.ts";

export const nodeRuntime: FooterRuntime = {
  homeDirectory: homedir(),
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
