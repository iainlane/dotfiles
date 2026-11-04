import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { runtimeFixture } from "./runtime.ts";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

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
  const publish = vi.fn<(event: string, value: unknown) => void>();
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
      publish(event, value);
      for (const callback of channels.get(event) ?? []) {
        callback(value);
      }
    },
  };
  const { api, context: ctx, runner } = await runtimeFixture(events);
  vi.spyOn(runner, "createContext").mockReturnValue(ctx);
  const model = ctx.model;

  if (model === undefined) {
    throw new Error("Expected the fixture model");
  }

  const response = Promise.withResolvers<Response>();
  const fetching = Promise.withResolvers<void>();
  const replacement = Promise.withResolvers<Response>();
  const replacementFetching = Promise.withResolvers<void>();
  const requests: (AbortSignal | null | undefined)[] = [];
  const dependencies = {
    fetch: vi.fn<typeof fetch>((_input, init) => {
      requests.push(init?.signal);
      if (requests.length === 1) {
        fetching.resolve();
        return response.promise;
      }
      replacementFetching.resolve();
      return replacement.promise;
    }),
    homedir: () => directory,
    env: { OPENAI_CODEX_OAUTH_TOKEN: "fixture" },
    readFile: () => {},
    fileExists: () => false,
    execFileSync: () => "",
  };
  const { default: core, fixtureIdle } = await vi.importActual<{
    default: (api: ExtensionAPI, deps: typeof dependencies) => void;
    fixtureIdle: WeakMap<ExtensionAPI, () => Promise<void>>;
  }>("../.fixtures/pi-sub-core/index.ts");
  const configuration = await vi.importActual<{
    SETTINGS_PATH: string;
    loadSettings: () => { behavior: { refreshOnTurnStart: boolean } };
  }>("../.fixtures/pi-sub-core/src/settings.ts");
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
    const settled = await Promise.race([
      turn.then(() => true),
      new Promise<boolean>((resolve) => {
        setTimeout(() => resolve(false), 2000);
      }),
    ]);
    expect(settled).toBe(true);
    const reply = vi.fn<(value: unknown) => void>();
    const entries = [...(channels.get("sub-core:request") ?? [])].map(
      (callback) => callback({ type: "entries", force: true, reply }),
    );
    let replacementCache: string | undefined;
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
      replacement.resolve(
        Response.json({
          rate_limit: {
            primary_window: {
              used_percent: 42,
              reset_at: 2_000_000_000,
              limit_window_seconds: 18_000,
            },
          },
        }),
      );
      await Promise.all(completed);
      await idle();
      replacementCache = await readFile(
        join(directory, "cache/sub-core/cache.json"),
        "utf8",
      );
    } else if (reason === "model replacement") {
      const replacementContext = {
        ...ctx,
        model: { ...model, provider: "fixture", id: "no-provider" },
      };
      vi.spyOn(runner, "createContext").mockReturnValue(replacementContext);
      await runner.emit({
        type: "model_select",
        model: replacementContext.model,
        previousModel: model,
        source: "set",
      });
    } else {
      await runner.emit({ type: "session_shutdown", reason: "quit" });
    }
    expect(requests[0]?.aborted).toBe(true);
    const before = publish.mock.calls.slice();
    response.resolve(
      Response.json({
        rate_limit: {
          primary_window: {
            used_percent: 1,
            reset_at: 2_000_000_000,
            limit_window_seconds: 18_000,
          },
        },
      }),
    );
    await turn;
    await Promise.all(entries);
    await drained;
    expect(reply.mock.calls).toStrictEqual(
      reason === "model replacement" || reason === "successful replacement"
        ? [[{ entries: [] }]]
        : [],
    );
    expect(dependencies.fetch).toHaveBeenCalledTimes(
      reason === "successful replacement" ? 2 : 1,
    );
    expect(
      publish.mock.calls.filter(([event]) => event === "sub-core:update-all"),
    ).toStrictEqual(
      before.filter(([event]) => event === "sub-core:update-all"),
    );
    const cached = await readFile(
      join(directory, "cache/sub-core/cache.json"),
      "utf8",
    ).catch((error: unknown): string | undefined => {
      if (
        error instanceof Error &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        return undefined;
      }
      throw error;
    });
    expect(cached).toBe(replacementCache);
  } finally {
    response.resolve(Response.json({}));
    replacement.resolve(Response.json({}));
    await runner.emit({ type: "session_shutdown", reason: "quit" });
    await turn;
    await rm(directory, { recursive: true, force: true });
  }
});
