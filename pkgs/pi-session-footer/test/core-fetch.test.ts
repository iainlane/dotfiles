import { writeFileSync } from "node:fs";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, expect, it, vi } from "vitest";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

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
    }>("../.fixtures/pi-sub-core/src/settings-types.ts");
    const { fetchUsageForProvider } = await vi.importActual<{
      fetchUsageForProvider: (
        dependencies: { fetch: typeof fetch },
        settings: Settings,
        provider: string,
        options?: { force: boolean },
      ) => Promise<{ usage?: { windows: { usedPercent: number }[] } }>;
    }>("../.fixtures/pi-sub-core/src/usage/fetch.ts");
    const settings = getDefaultSettings();
    settings.behavior.refreshInterval = 60;
    settings.behavior.minRefreshInterval = 0;
    settings.providers.codex.enabled = "on";
    const response = Promise.withResolvers<Response>();
    const dependencies = {
      fetch: vi.fn<typeof fetch>(() => {
        return response.promise;
      }),
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
      response.resolve(
        Response.json({
          rate_limit: {
            primary_window: {
              used_percent: 2,
              reset_at: 2_000_000_000,
              limit_window_seconds: 18_000,
            },
          },
        }),
      );
      const results = await Promise.all([cached, forced, another]);
      expect(dependencies.fetch).toHaveBeenCalledTimes(1);
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
      onCacheSnapshot: (callback: () => void) => () => void;
    }>("../.fixtures/pi-sub-core/src/cache.ts");
    const publish = vi.fn<() => void>();
    const stop = onCacheSnapshot(publish);
    const controller = new AbortController();
    controller.abort(new Error("Status update cancelled"));
    await expect(
      updateCacheStatus(
        "codex",
        { indicator: "none" },
        { signal: controller.signal },
      ),
    ).rejects.toThrow("Status update cancelled");
    expect(publish).not.toHaveBeenCalled();
    stop();
    await expect(
      readFile(join(root, "cache/sub-core/cache.json")),
    ).rejects.toMatchObject({ code: "ENOENT" });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
