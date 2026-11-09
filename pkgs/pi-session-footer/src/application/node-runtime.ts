import { homedir } from "node:os";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { readGit } from "#footer/integrations/git.ts";
import type { FooterRuntime } from "./runtime.ts";
import { NodeSettingsStore } from "#footer/configuration/node-settings-store.ts";

export const nodeRuntime: FooterRuntime = {
  homeDirectory: homedir(),
  get settingsPath() {
    return join(getAgentDir(), "session-footer.json");
  },
  settingsStore: new NodeSettingsStore(() =>
    join(getAgentDir(), "session-footer.json"),
  ),
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
