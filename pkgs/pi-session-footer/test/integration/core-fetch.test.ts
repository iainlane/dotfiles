import { existsSync, writeFileSync } from "node:fs";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, expect, it, vi } from "vitest";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

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
    const response = Promise.withResolvers<Response>();
    const responses = [response.promise];
    const dependencies = {
      fetch: async () => responses.shift() ?? usage(3),
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
      response.resolve(usage(2));
      const results = await Promise.all([cached, forced, another]);
      expect(
        results.map((result) => result.usage?.windows[0]?.usedPercent),
      ).toStrictEqual([1, 2, 2]);
    } finally {
      response.resolve(Response.json({}));
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
    const published: unknown[] = [];
    const stop = onCacheSnapshot((cache) => {
      published.push(cache);
    });
    const controller = new AbortController();
    controller.abort(new Error("Status update cancelled"));
    await expect(
      updateCacheStatus(
        "codex",
        { indicator: "none" },
        { signal: controller.signal },
      ),
    ).rejects.toThrow("Status update cancelled");
    expect(published).toStrictEqual([]);
    stop();
    expect(existsSync(join(root, "cache/sub-core/cache.json"))).toBe(false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
