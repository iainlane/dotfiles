import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { readQuota } from "../src/quota.ts";
import { renderFooter } from "../src/render.ts";
import { createSnapshot } from "../src/state.ts";

interface Status {
  indicator: "none";
  description: string;
}

type Handler = (event: unknown, context: ExtensionContext) => unknown;

const dependencies = {
  fetch: vi.fn<typeof fetch>(),
  homedir: () => "/fixture",
  env: {},
  readFile: () => undefined,
  fileExists: () => false,
  execFileSync: () => "",
};

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

it("preserves quota fetch time through actual sub-core cache notifications", async () => {
  vi.useFakeTimers();

  const now = Date.UTC(2026, 9, 20, 12);
  const fetchedAt = now - 10_000;
  const resetAt = now + 172_800_000;
  const directory = await mkdtemp(join(tmpdir(), "pi-footer-core-cache-"));

  vi.setSystemTime(now);
  vi.stubEnv("PI_CODING_AGENT_DIR", directory);

  await mkdir(join(directory, "cache/sub-core"), { recursive: true });
  await writeFile(
    join(directory, "pi-sub-core-settings.json"),
    JSON.stringify({
      version: 3,
      behavior: { refreshInterval: 0 },
      statusRefresh: { refreshInterval: 0 },
    }),
  );
  await writeFile(
    join(directory, "cache/sub-core/cache.json"),
    JSON.stringify({
      codex: {
        fetchedAt,
        usage: {
          provider: "codex",
          displayName: "Codex Plan",
          windows: [
            {
              label: "Week",
              usedPercent: 42,
              resetAt: new Date(resetAt).toISOString(),
              windowSeconds: 604_800,
            },
          ],
        },
      },
    }),
  );

  const hooks = new Map<string, Handler>();
  const listeners = new Map<string, Set<(value: unknown) => void>>();
  const snapshots: ReturnType<typeof readQuota>[] = [];
  const rendered: string[] = [];
  const api = {
    on: (event: string, handler: Handler) => hooks.set(event, handler),
    registerCommand: vi.fn(),
    registerTool: vi.fn(),
    events: {
      on(event: string, listener: (value: unknown) => void) {
        const handlers = listeners.get(event) ?? new Set();

        handlers.add(listener);
        listeners.set(event, handlers);

        return () => {
          handlers.delete(listener);
        };
      },
      emit(event: string, value: unknown) {
        if (event === "sub-core:update-current") {
          const state = createSnapshot(Date.now(), "/fixture");

          state.quota = readQuota(value);
          snapshots.push(state.quota);
          rendered.push(renderFooter(state, 120)[1]?.trim() ?? "");
        }

        for (const listener of listeners.get(event) ?? []) listener(value);
      },
    },
  } as unknown as ExtensionAPI;
  const context = {
    model: { provider: "openai-codex", id: "fixture" },
  } as unknown as ExtensionContext;

  try {
    const { default: core } = await vi.importActual<{
      default(api: ExtensionAPI, deps: typeof dependencies): void;
    }>("../.fixtures/pi-sub-core/index.ts");
    const cache = await vi.importActual<{
      updateCacheStatus(provider: "codex", status: Status): Promise<void>;
    }>("../.fixtures/pi-sub-core/src/cache.ts");

    core(api, dependencies);

    await hooks.get("session_start")?.({ reason: "startup" }, context);
    await vi.advanceTimersByTimeAsync(0);

    for (const elapsed of [11_000, 31_000, 300_001]) {
      vi.setSystemTime(fetchedAt + elapsed);
      await cache.updateCacheStatus("codex", {
        indicator: "none",
        description: `Status update ${elapsed}`,
      });
    }

    const expected = {
      provider: "codex",
      windows: [{ label: "Week", used: 42, resetAt, windowSeconds: 604_800 }],
      lastSuccessAt: fetchedAt,
      error: undefined,
      account: undefined,
      source: undefined,
    };

    expect({ snapshots, rendered }).toStrictEqual({
      snapshots: Array(4).fill(expected),
      rendered: [
        " week 42% used (2d)  $0.00  0m",
        " week 42% used (1d23h)  $0.00  0m",
        " week 42% used (1d23h) stale  $0.00  0m",
        " week unavailable  $0.00  0m",
      ],
    });

    expect(dependencies.fetch).not.toHaveBeenCalled();
  } finally {
    await hooks.get("session_shutdown")?.({ reason: "quit" }, context);
    await rm(directory, { recursive: true, force: true });
  }
});
