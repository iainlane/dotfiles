import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { bindModel } from "#test/support/bound-runner.ts";
import { runtimeFixture } from "#test/support/runtime.ts";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

async function readCache(directory: string): Promise<unknown> {
  const path = join(directory, "cache/sub-core/cache.json");
  return existsSync(path)
    ? JSON.parse(await readFile(path, "utf8"))
    : undefined;
}

it.each([
  "shutdown",
  "model replacement",
  "cycle cancellation",
  "successful replacement",
])("revokes late quota replies and cache writes on %s", async (reason) => {
  const directory = await mkdtemp(join(tmpdir(), "pi-core-lifecycle-"));
  vi.stubEnv("PI_CODING_AGENT_DIR", directory);
  expect(getAgentDir()).toBe(directory);
  await writeFile(
    join(directory, "pi-sub-core-settings.json"),
    JSON.stringify({
      version: 3,
      behavior: {
        refreshInterval: 0,
        minRefreshInterval: 0,
        refreshOnTurnStart: true,
        refreshOnToolResult: false,
      },
      statusRefresh: {
        refreshInterval: 0,
        refreshOnTurnStart: false,
        refreshOnToolResult: false,
      },
      providers: { codex: { enabled: "on", fetchStatus: false } },
    }),
  );
  const channels = new Map<string, Set<(value: unknown) => unknown>>();
  const published: { event: string; value: unknown }[] = [];
  const events = {
    on(event: string, callback: (value: unknown) => unknown) {
      const callbacks = channels.get(event) ?? new Set();
      callbacks.add(callback);
      channels.set(event, callbacks);
      return () => {
        callbacks.delete(callback);
      };
    },
    emit(event: string, value: unknown) {
      published.push({ event, value });
      for (const callback of channels.get(event) ?? []) {
        callback(value);
      }
    },
  };
  const { api, context: ctx, runner } = await runtimeFixture(events);
  const model = ctx.model;

  if (model === undefined) {
    throw new Error("Expected the fixture model");
  }

  let selected = model;

  bindModel(runner, () => selected);

  const response = Promise.withResolvers<Response>();
  const fetching = Promise.withResolvers<void>();
  const replacement = Promise.withResolvers<Response>();
  const replacementFetching = Promise.withResolvers<void>();
  const held = [
    { started: fetching, response: response.promise },
    ...(reason === "successful replacement"
      ? [{ started: replacementFetching, response: replacement.promise }]
      : []),
  ];
  const requests: (AbortSignal | null | undefined)[] = [];
  const dependencies = {
    fetch: async (_input: string | URL | Request, init?: RequestInit) => {
      requests.push(init?.signal);

      const next = held.shift();

      if (next === undefined) {
        return usage(99);
      }

      next.started.resolve();

      return next.response;
    },
    homedir: () => directory,
    env: { OPENAI_CODEX_OAUTH_TOKEN: "fixture" },
    readFile: () => {},
    fileExists: () => false,
    execFileSync: () => "",
  };
  const { default: core, fixtureIdle } = await vi.importActual<{
    default: (api: ExtensionAPI, deps: typeof dependencies) => void;
    fixtureIdle: WeakMap<ExtensionAPI, () => Promise<void>>;
  }>("#fixtures/pi-sub-core/index.ts");
  const configuration = await vi.importActual<{
    SETTINGS_PATH: string;
    loadSettings: () => { behavior: { refreshOnTurnStart: boolean } };
  }>("#fixtures/pi-sub-core/src/settings.ts");
  expect({
    path: configuration.SETTINGS_PATH,
    refresh: configuration.loadSettings().behavior.refreshOnTurnStart,
  }).toStrictEqual({
    path: join(directory, "pi-sub-core-settings.json"),
    refresh: true,
  });
  core(api, dependencies);
  const idle = fixtureIdle.get(api);
  if (idle === undefined) {
    throw new Error("Expected the quota fixture's idle probe.");
  }
  let turn: Promise<unknown> | undefined;

  try {
    await runner.emit({ type: "session_start", reason: "startup" });
    turn = Promise.resolve(
      reason === "cycle cancellation"
        ? [...(channels.get("sub-core:action") ?? [])].map((callback) =>
            callback({ type: "cycleProvider" }),
          )
        : runner.emit({
            type: "turn_start",
            turnIndex: 0,
            timestamp: Date.now(),
          }),
    );
    await fetching.promise;
    const drained = idle();
    // The first quota response is released only after the turn, so a turn
    // that waited for the fetch would never finish.
    await turn;
    const replies: unknown[] = [];
    const entries = [...(channels.get("sub-core:request") ?? [])].map(
      (callback) =>
        callback({
          type: "entries",
          force: true,
          reply: (value: unknown) => {
            replies.push(value);
          },
        }),
    );
    if (reason === "successful replacement") {
      await runner.emit({
        type: "model_select",
        model,
        previousModel: model,
        source: "set",
      });
      await replacementFetching.promise;
      const completed = [...(channels.get("sub-core:request") ?? [])].map(
        (callback) =>
          callback({ type: "entries", force: true, reply: () => {} }),
      );
      replacement.resolve(usage(42));
      await Promise.all(completed);
      await idle();
    } else if (reason === "model replacement") {
      selected = { ...model, provider: "fixture", id: "no-provider" };
      await runner.emit({
        type: "model_select",
        model: selected,
        previousModel: model,
        source: "set",
      });
    } else {
      await runner.emit({ type: "session_shutdown", reason: "quit" });
    }
    expect(requests[0]?.aborted).toBe(true);
    const before = published.length;
    response.resolve(usage(1));
    await Promise.all(entries);
    await drained;
    expect(replies).toStrictEqual(
      reason === "model replacement" || reason === "successful replacement"
        ? [{ entries: [] }]
        : [],
    );
    expect(published.slice(before)).toStrictEqual([]);
    const now: unknown = expect.any(Number);
    const description: unknown = expect.any(String);
    const replacementCache = {
      codex: {
        fetchedAt: now,
        statusFetchedAt: now,
        usage: {
          provider: "codex",
          displayName: "Codex Plan",
          windows: [
            {
              label: "5h",
              usedPercent: 42,
              windowSeconds: 18_000,
              resetDescription: description,
              resetAt: new Date(2_000_000_000_000).toISOString(),
            },
          ],
          credentialSource: "environment",
          lastSuccessAt: now,
        },
        status: { indicator: "none" },
      },
    };
    expect(await readCache(directory)).toStrictEqual(
      reason === "successful replacement" ? replacementCache : undefined,
    );
  } finally {
    response.resolve(Response.json({}));
    replacement.resolve(Response.json({}));
    await runner.emit({ type: "session_shutdown", reason: "quit" });
    await turn;
    await rm(directory, { recursive: true, force: true });
  }
});
