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
  vi.useRealTimers();
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

interface HeldReply {
  arrived: Promise<void>;
  release(usedPercent: number): void;
}

/**
 * A Codex usage endpoint whose replies the test releases. A request waits for
 * the reply that was held when it arrived. The endpoint ignores the request's
 * signal, so a reply can arrive after the client has cancelled the request.
 */
class UsageEndpoint {
  private current:
    | { arrived: PromiseWithResolvers<void>; reply: Promise<number> }
    | undefined;
  private readonly releases: (() => void)[] = [];

  hold(): HeldReply {
    const arrived = Promise.withResolvers<void>();
    const reply = Promise.withResolvers<number>();

    this.current = { arrived, reply: reply.promise };
    this.releases.push(() => reply.resolve(0));

    return {
      arrived: arrived.promise,
      release: (usedPercent) => reply.resolve(usedPercent),
    };
  }

  /** Answers every request that is still waiting. */
  releaseAll(): void {
    for (const release of this.releases) {
      release();
    }
  }

  readonly fetch = async (): Promise<Response> => {
    const current = this.current;

    if (current === undefined) {
      throw new Error("The usage endpoint has no reply to send");
    }

    current.arrived.resolve();

    return usage(await current.reply);
  };
}

it.each([
  "shutdown",
  "model replacement",
  "cycle cancellation",
  "successful replacement",
])("revokes late quota replies and cache writes on %s", async (reason) => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(Date.UTC(2026, 9, 20, 12));

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
  const latest = new Map<string, unknown>();
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
      latest.set(event, value);
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

  const endpoint = new UsageEndpoint();
  const stale = endpoint.hold();
  const dependencies = {
    fetch: endpoint.fetch,
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
    await stale.arrived;
    const drained = idle();
    // The first quota response is released only after the turn, so a turn
    // that waited for the fetch would never finish.
    await turn;
    let answer: unknown;
    const entries = [...(channels.get("sub-core:request") ?? [])].map(
      (callback) =>
        callback({
          type: "entries",
          force: true,
          reply: (value: unknown) => {
            answer = value;
          },
        }),
    );
    if (reason === "successful replacement") {
      const current = endpoint.hold();
      await runner.emit({
        type: "model_select",
        model,
        previousModel: model,
        source: "set",
      });
      await current.arrived;
      const completed = [...(channels.get("sub-core:request") ?? [])].map(
        (callback) =>
          callback({ type: "entries", force: true, reply: () => {} }),
      );
      current.release(42);
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
    const published = new Map(latest);
    stale.release(1);
    await Promise.all(entries);
    await drained;
    const now = Date.now();
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
              resetDescription: "2401d15h",
              resetAt: new Date(2_000_000_000_000).toISOString(),
            },
          ],
          credentialSource: "environment",
          lastSuccessAt: now,
        },
        status: { indicator: "none" },
      },
    };
    expect({
      answer,
      published: latest,
      cache: await readCache(directory),
    }).toStrictEqual({
      answer:
        reason === "model replacement" || reason === "successful replacement"
          ? { entries: [] }
          : undefined,
      published,
      cache: reason === "successful replacement" ? replacementCache : undefined,
    });
  } finally {
    endpoint.releaseAll();
    await runner.emit({ type: "session_shutdown", reason: "quit" });
    await turn;
    await rm(directory, { recursive: true, force: true });
  }
});
