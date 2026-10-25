import { afterAll, afterEach, beforeAll, expect, it, vi } from "vitest";
import { http, HttpResponse } from "msw";
import { setupServer } from "msw/node";

interface Provider {
  fetchUsage(deps: {
    fetch: typeof fetch;
    readFile(path: string): string | undefined;
    fileExists(path: string): boolean;
    execFileSync(): string;
    homedir(): string;
    env: NodeJS.ProcessEnv;
  }): Promise<{
    windows: {
      label: string;
      usedPercent: number;
      resetAt?: string;
      windowSeconds?: number;
    }[];
    accountId?: string;
    credentialSource?: string;
  }>;
}

const server = setupServer();

beforeAll(() => {
  server.listen({ onUnhandledRequest: "error" });
});

afterEach(() => {
  server.resetHandlers();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

afterAll(() => {
  server.close();
});

const stringMatcher: unknown = expect.any(String);

const dependencies = {
  fetch: globalThis.fetch,
  homedir: () => "/fixture",
  env: {},
  readFile: (): undefined => undefined,
  fileExists: () => false,
  execFileSync: () => "",
};

it("publishes Codex duration only when reported and identifies the credential source", async () => {
  server.use(
    http.get("https://chatgpt.com/backend-api/wham/usage", ({ request }) => {
      expect(request.headers.get("ChatGPT-Account-Id")).toBe("account-a");

      return HttpResponse.json({
        rate_limit: {
          primary_window: {
            used_percent: 15,
            reset_at: 1_800_000_000,
            limit_window_seconds: 18_000,
          },
          secondary_window: { used_percent: 18, reset_at: 1_800_100_000 },
        },
      });
    }),
  );

  const { CodexProvider } = await vi.importActual<{
    CodexProvider: new () => Provider;
  }>("../.fixtures/pi-sub-core/src/providers/impl/codex.ts");
  const result = await new CodexProvider().fetchUsage({
    ...dependencies,
    fetch: globalThis.fetch,
    env: {
      OPENAI_CODEX_OAUTH_TOKEN: "fixture",
      OPENAI_CODEX_ACCOUNT_ID: "account-a",
    },
  });

  expect(result).toStrictEqual({
    provider: "codex",
    displayName: "Codex Plan",
    accountId: "account-a",
    credentialSource: "environment",
    windows: [
      {
        label: "5h",
        usedPercent: 15,
        windowSeconds: 18_000,
        resetAt: new Date(1_800_000_000_000).toISOString(),
        resetDescription: stringMatcher,
      },
      {
        label: "Day",
        usedPercent: 18,
        windowSeconds: undefined,
        resetAt: new Date(1_800_100_000_000).toISOString(),
        resetDescription: stringMatcher,
      },
    ],
  });
});

it("publishes exact Anthropic durations without inventing account identity", async () => {
  server.use(
    http.get("https://api.anthropic.com/api/oauth/usage", () =>
      HttpResponse.json({
        five_hour: { utilization: 15 },
        seven_day: { utilization: 18 },
      }),
    ),
  );

  const { AnthropicProvider } = await vi.importActual<{
    AnthropicProvider: new () => Provider;
  }>("../.fixtures/pi-sub-core/src/providers/impl/anthropic.ts");

  expect(
    await new AnthropicProvider().fetchUsage({
      ...dependencies,
      fetch: globalThis.fetch,
      env: { ANTHROPIC_OAUTH_TOKEN: "fixture" },
    }),
  ).toStrictEqual({
    provider: "anthropic",
    displayName: "Claude Plan",
    credentialSource: "environment",
    extraUsageEnabled: false,
    fiveHourUsage: 15,
    windows: [
      {
        label: "5h",
        usedPercent: 15,
        windowSeconds: 18_000,
        resetAt: undefined,
        resetDescription: undefined,
      },
      {
        label: "Week",
        usedPercent: 18,
        windowSeconds: 604_800,
        resetAt: undefined,
        resetDescription: undefined,
      },
    ],
  });
});

it("reads the todo visibility flag once per overlay without caching other config getters", async () => {
  const config = await vi.importActual<{
    loadConfig(): { widget?: { enabled?: boolean } };
  }>("../.fixtures/rpiv-todo/config.ts");
  const read = vi
    .spyOn(config, "loadConfig")
    .mockReturnValue({ widget: { enabled: true } });
  const { TodoOverlay } = await vi.importActual<{
    TodoOverlay: new () => { setUICtx(ctx: unknown): void; update(): void };
  }>("../.fixtures/rpiv-todo/todo-overlay.ts");
  const overlay = new TodoOverlay();
  const setWidget = vi.fn<(id: string, widget: unknown) => void>();

  overlay.setUICtx({ setWidget });
  overlay.update();
  overlay.update();

  expect({
    reads: read.mock.calls,
    widgets: setWidget.mock.calls,
  }).toStrictEqual({ reads: [[]], widgets: [] });
});

it("disables only the todo widget through its configuration", async () => {
  const directory = await import("node:fs/promises").then(async (fs) => {
    const os = await import("node:os");
    const path = await import("node:path");

    return fs.mkdtemp(path.join(os.tmpdir(), "pi-footer-todo-"));
  });

  vi.stubEnv("XDG_CONFIG_HOME", directory);

  const fs = await import("node:fs/promises");

  await fs.mkdir(`${directory}/rpiv-todo`, { recursive: true });
  await fs.writeFile(
    `${directory}/rpiv-todo/config.json`,
    JSON.stringify({ widget: { enabled: false } }),
  );

  const { TodoOverlay } = await vi.importActual<{
    TodoOverlay: new () => { setUICtx(ctx: unknown): void; update(): void };
  }>("../.fixtures/rpiv-todo/todo-overlay.ts");
  const setWidget = vi.fn<(id: string, widget: unknown) => void>();
  const overlay = new TodoOverlay();

  overlay.setUICtx({ setWidget });
  overlay.update();

  expect(setWidget.mock.calls).toStrictEqual([]);

  await fs.rm(directory, { recursive: true, force: true });
});
