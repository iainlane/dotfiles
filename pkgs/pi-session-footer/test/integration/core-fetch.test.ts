import { existsSync, writeFileSync } from "node:fs";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, expect, it, vi } from "vitest";

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.resetModules();
});

async function readCache(directory: string): Promise<unknown> {
  const path = join(directory, "cache/sub-core/cache.json");
  return existsSync(path)
    ? JSON.parse(await readFile(path, "utf8"))
    : undefined;
}

function usage(usedPercent: number): Response {
  return Response.json({
    rate_limit: {
      primary_window: {
        used_percent: usedPercent,
        reset_at: 2_000_000_000,
        limit_window_seconds: 18_000,
      },
    },
  });
}

it.each(["cached", "cache filled during lookup"])(
  "preserves forced refresh semantics (%s)",
  async (scenario) => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.UTC(2026, 9, 20, 12));

    const root = await mkdtemp(join(tmpdir(), "pi-core-force-"));
    vi.stubEnv("PI_CODING_AGENT_DIR", root);
    expect(getAgentDir()).toBe(root);
    await mkdir(join(root, "cache/sub-core"), { recursive: true });
    const cachePath = join(root, "cache/sub-core/cache.json");
    const cacheContent = JSON.stringify({
      codex: {
        fetchedAt: Date.now(),
        usage: {
          provider: "codex",
          windows: [{ label: "5h", usedPercent: 1 }],
        },
      },
    });
    if (scenario === "cached") {
      writeFileSync(cachePath, cacheContent);
    }
    interface Settings {
      behavior: { refreshInterval: number; minRefreshInterval: number };
      providers: { codex: { enabled: "on" } };
    }
    const { getDefaultSettings } = await vi.importActual<{
      getDefaultSettings: () => Settings;
    }>("#fixtures/pi-sub-core/src/settings-types.ts");
    const { fetchUsageForProvider } = await vi.importActual<{
      fetchUsageForProvider: (
        dependencies: { fetch: typeof fetch },
        settings: Settings,
        provider: string,
        options?: { force: boolean },
      ) => Promise<{ usage?: { windows: { usedPercent: number }[] } }>;
    }>("#fixtures/pi-sub-core/src/usage/fetch.ts");
    const settings = getDefaultSettings();
    settings.behavior.refreshInterval = 60;
    settings.behavior.minRefreshInterval = 0;
    settings.providers.codex.enabled = "on";
    const usedPercent = Promise.withResolvers<number>();
    const dependencies = {
      fetch: async () => usage(await usedPercent.promise),
      homedir: () => root,
      env: { OPENAI_CODEX_OAUTH_TOKEN: "fixture" },
      readFile: () => {},
      fileExists: () => false,
      execFileSync: () => "",
    };
    try {
      const cached = fetchUsageForProvider(dependencies, settings, "codex");
      if (scenario === "cache filled during lookup") {
        writeFileSync(cachePath, cacheContent);
        await Promise.resolve();
      }
      const forced = fetchUsageForProvider(dependencies, settings, "codex", {
        force: true,
      });
      const another = fetchUsageForProvider(dependencies, settings, "codex", {
        force: true,
      });
      usedPercent.resolve(2);
      const results = await Promise.all([cached, forced, another]);
      const now = Date.now();
      const windows = [{ label: "5h", usedPercent: 1 }];
      const fetched = {
        status: { indicator: "none" },
        statusFetchedAt: now,
        usage: {
          accountId: undefined,
          credentialSource: "environment",
          displayName: "Codex Plan",
          lastSuccessAt: now,
          provider: "codex",
          windows: [
            {
              label: "5h",
              resetAt: new Date(2_000_000_000_000).toISOString(),
              resetDescription: "2401d15h",
              usedPercent: 2,
              windowSeconds: 18_000,
            },
          ],
        },
      };
      expect(results).toStrictEqual([
        scenario === "cached"
          ? {
              status: undefined,
              usage: {
                lastSuccessAt: now,
                provider: "codex",
                status: undefined,
                windows,
              },
            }
          : {
              status: undefined,
              statusFetchedAt: undefined,
              usage: { lastSuccessAt: now, provider: "codex", windows },
            },
        fetched,
        fetched,
      ]);
    } finally {
      usedPercent.resolve(0);
      await rm(root, { recursive: true, force: true });
    }
  },
);

it("does not publish a cancelled status-cache update", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-core-status-"));
  vi.stubEnv("PI_CODING_AGENT_DIR", root);
  expect(getAgentDir()).toBe(root);
  try {
    const { updateCacheStatus, onCacheSnapshot } = await vi.importActual<{
      updateCacheStatus: (
        provider: string,
        status: { indicator: "none" },
        options: { signal: AbortSignal },
      ) => Promise<void>;
      onCacheSnapshot: (callback: (cache: unknown) => void) => () => void;
    }>("#fixtures/pi-sub-core/src/cache.ts");
    let published: unknown;
    const stop = onCacheSnapshot((cache) => {
      published = cache;
    });
    const cancelled = new Error("Status update cancelled");
    const controller = new AbortController();
    controller.abort(cancelled);
    const update = updateCacheStatus(
      "codex",
      { indicator: "none" },
      { signal: controller.signal },
    );
    await expect(update).rejects.toBe(cancelled);
    stop();
    expect({ published, cache: await readCache(root) }).toStrictEqual({
      published: undefined,
      cache: undefined,
    });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
