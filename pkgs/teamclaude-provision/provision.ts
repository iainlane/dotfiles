import { execFile } from "node:child_process";
import { mkdir, readFile } from "node:fs/promises";
import { userInfo } from "node:os";
import { setTimeout } from "node:timers/promises";
import { promisify } from "node:util";
import { main } from "./provisioner.ts";

const launchctl = promisify(execFile);

try {
  await main(process.argv.slice(2), {
    readText: (path) => readFile(path, "utf8"),
    prepareDirectory: async (path) => {
      await mkdir(path, { recursive: true, mode: 0o700 });
    },
    importModule: (url) => import(url),
    sopsStatus: async () => {
      const sopsJob = `gui/${userInfo().uid}/org.nix-community.home.sops-nix`;

      try {
        const result = await launchctl("/bin/launchctl", ["print", sopsJob]);

        return result.stdout;
      } catch {
        return "";
      }
    },
    clock: { now: Date.now, pause: () => setTimeout(100) },
    requestReload: (url, apiKey) =>
      fetch(url, {
        method: "POST",
        headers: { "x-api-key": apiKey },
        signal: AbortSignal.timeout(5000),
      }),
  });
} catch (error) {
  console.error("teamclaude: provisioning failed:", error);
  process.exitCode = 1;
}
