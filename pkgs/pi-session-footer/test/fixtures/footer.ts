import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createSessionFooter } from "#footer/application/extension.ts";
import { nodeRuntime } from "#footer/application/node-runtime.ts";
import { FileClock } from "#test/fixtures/clock.ts";

/** The session footer with the production runtime and the test's clock. */
export default function footer(pi: ExtensionAPI): void {
  createSessionFooter({
    homeDirectory: nodeRuntime.homeDirectory,
    get settingsPath() {
      return nodeRuntime.settingsPath;
    },
    settingsStore: nodeRuntime.settingsStore,
    requestId: () => nodeRuntime.requestId(),
    readGit: (cwd, now) => nodeRuntime.readGit(cwd, now),
    reportError: nodeRuntime.reportError,
    clock: new FileClock(),
  })(pi);
}
