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

beforeAll(async () => {
  server.listen({ onUnhandledRequest: "error" });
  await vi.importActual("../.fixtures/pi-sub-core/src/providers/impl/codex.ts");
  await vi.importActual(
    "../.fixtures/pi-sub-core/src/providers/impl/anthropic.ts",
  );
}, 30_000);

afterEach(() => {
  server.resetHandlers();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

afterAll(() => server.close());

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

it("reads the current Claude credential file on every quota request", async () => {
  vi.spyOn(Date, "now").mockReturnValue(2_000_000_000_000);
  let token = "first";
  const observed: (string | null)[] = [];
  server.use(
    http.get("https://api.anthropic.com/api/oauth/usage", ({ request }) => {
      observed.push(request.headers.get("authorization"));
      return HttpResponse.json({ five_hour: { utilization: 15 } });
    }),
  );
  const { AnthropicProvider } = await vi.importActual<{
    AnthropicProvider: new () => Provider;
  }>("../.fixtures/pi-sub-core/src/providers/impl/anthropic.ts");
  const provider = new AnthropicProvider();
  const deps = {
    ...dependencies,
    fetch: globalThis.fetch,
    env: { CLAUDE_CONFIG_DIR: "/fixture/claude" },
    readFile: (path: string) =>
      path === "/fixture/claude/.credentials.json"
        ? JSON.stringify({
            claudeAiOauth: {
              accessToken: token,
              scopes: ["user:profile"],
              expiresAt: 2_000_000_003_600,
            },
          })
        : undefined,
  };
  await provider.fetchUsage(deps);
  token = "second";
  await provider.fetchUsage(deps);
  expect(observed).toStrictEqual(["Bearer first", "Bearer second"]);
});

it.each([
  {
    credential: { type: "oauth", access: "pi", expires: 2_000_000_000_001 },
    env: {},
    token: "pi",
    source: "pi",
  },
  {
    credential: { type: "oauth", access: "pi", expires: 2_000_000_000_000 },
    env: {},
    token: "claude",
    source: "claude-code-file",
  },
  {
    credential: { type: "oauth", access: "pi", expires: 1_999_999_999_999 },
    env: {},
    token: "claude",
    source: "claude-code-file",
  },
  {
    credential: { type: "oauth", access: "pi" },
    env: {},
    token: "claude",
    source: "claude-code-file",
  },
  {
    credential: { type: "oauth", access: "pi", expires: "tomorrow" },
    env: {},
    token: "claude",
    source: "claude-code-file",
  },
  {
    credential: { type: "api_key", access: "pi", expires: 2_000_000_000_001 },
    env: {},
    token: "claude",
    source: "claude-code-file",
  },
  {
    credential: { type: "oauth", access: "pi", expires: 0 },
    env: { ANTHROPIC_OAUTH_TOKEN: "override" },
    token: "override",
    source: "environment",
  },
])(
  "selects $source credentials when Pi auth is $credential",
  async ({ credential, env, token, source }) => {
    vi.spyOn(Date, "now").mockReturnValue(2_000_000_000_000);
    const observed: (string | null)[] = [];
    server.use(
      http.get("https://api.anthropic.com/api/oauth/usage", ({ request }) => {
        observed.push(request.headers.get("authorization"));
        return HttpResponse.json({ five_hour: { utilization: 15 } });
      }),
    );
    const { AnthropicProvider } = await vi.importActual<{
      AnthropicProvider: new () => Provider;
    }>("../.fixtures/pi-sub-core/src/providers/impl/anthropic.ts");
    const files = new Map([
      [
        "/fixture/.pi/agent/auth.json",
        JSON.stringify({ anthropic: credential }),
      ],
      [
        "/fixture/.claude/.credentials.json",
        JSON.stringify({
          claudeAiOauth: {
            accessToken: "claude",
            scopes: ["user:profile"],
            expiresAt: 2_000_000_003_600,
          },
        }),
      ],
    ]);
    const result = await new AnthropicProvider().fetchUsage({
      ...dependencies,
      fetch: globalThis.fetch,
      env,
      fileExists: (path) => files.has(path),
      readFile: (path) => files.get(path),
    });
    expect({ observed, result }).toStrictEqual({
      observed: [`Bearer ${token}`],
      result: {
        provider: "anthropic",
        displayName: "Claude Plan",
        credentialSource: source,
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
        ],
      },
    });
  },
);

it.each([
  {
    credential: { expiresAt: 2_000_000_000_001 },
    token: "file",
    source: "claude-code-file",
  },
  {
    credential: { expiresAt: 2_000_000_000_000 },
    token: "keychain",
    source: "claude-code-keychain",
  },
  {
    credential: { expiresAt: 1_999_999_999_999 },
    token: "keychain",
    source: "claude-code-keychain",
  },
  { credential: {}, token: "keychain", source: "claude-code-keychain" },
  {
    credential: { expiresAt: "tomorrow" },
    token: "keychain",
    source: "claude-code-keychain",
  },
  {
    credential: { expiresAt: null },
    token: "keychain",
    source: "claude-code-keychain",
  },
])(
  "selects $source credentials when Claude file expiry is $credential",
  async ({ credential, token, source }) => {
    vi.spyOn(Date, "now").mockReturnValue(2_000_000_000_000);
    const observed: (string | null)[] = [];
    server.use(
      http.get("https://api.anthropic.com/api/oauth/usage", ({ request }) => {
        observed.push(request.headers.get("authorization"));
        return HttpResponse.json({ five_hour: { utilization: 15 } });
      }),
    );
    const { AnthropicProvider } = await vi.importActual<{
      AnthropicProvider: new () => Provider;
    }>("../.fixtures/pi-sub-core/src/providers/impl/anthropic.ts");
    const result = await new AnthropicProvider().fetchUsage({
      ...dependencies,
      fetch: globalThis.fetch,
      readFile: (path) =>
        path === "/fixture/.claude/.credentials.json"
          ? JSON.stringify({
              claudeAiOauth: {
                accessToken: "file",
                scopes: ["user:profile"],
                ...credential,
              },
            })
          : undefined,
      execFileSync: () =>
        JSON.stringify({
          claudeAiOauth: {
            accessToken: "keychain",
            scopes: ["user:profile"],
            expiresAt: 2_000_000_003_600,
          },
        }),
    });
    expect({ observed, result }).toStrictEqual({
      observed: [`Bearer ${token}`],
      result: {
        provider: "anthropic",
        displayName: "Claude Plan",
        credentialSource: source,
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
        ],
      },
    });
  },
);

it("updates widget visibility from configuration without changing tasks", async () => {
  const fs = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const paths = await import("node:path");
  const directory = await fs.mkdtemp(paths.join(tmpdir(), "pi-footer-todo-"));
  vi.stubEnv("XDG_CONFIG_HOME", directory);
  const path = paths.join(directory, "rpiv-todo/config.json");
  await fs.mkdir(paths.join(directory, "rpiv-todo"), { recursive: true });
  await fs.writeFile(path, JSON.stringify({ widget: { enabled: true } }));
  const store = await vi.importActual<{
    replaceState: (
      id: string,
      state: {
        tasks: { id: number; subject: string; status: string }[];
        nextId: number;
      },
    ) => void;
    getState: (id: string) => unknown;
    setActiveRenderSession(id: string): void;
    evictSession(id: string): void;
    clearActiveRenderSession(): void;
  }>("../.fixtures/rpiv-todo/state/store.ts");
  const state = {
    tasks: [{ id: 1, subject: "A task", status: "pending" }],
    nextId: 2,
  };
  const { TodoOverlay } = await vi.importActual<{
    TodoOverlay: new () => {
      setUICtx(ctx: unknown): void;
      update(): void;
      isRegistered(): boolean;
    };
  }>("../.fixtures/rpiv-todo/todo-overlay.ts");
  const widget = vi.fn<(id: string, widget: unknown) => void>();
  const overlay = new TodoOverlay();
  store.replaceState("visibility", state);
  store.setActiveRenderSession("visibility");
  overlay.setUICtx({ setWidget: widget });
  try {
    const visible = [];
    for (const enabled of [true, false, true]) {
      // eslint-disable-next-line no-await-in-loop -- Each overlay update must read the preceding configuration write.
      await fs.writeFile(path, JSON.stringify({ widget: { enabled } }));
      overlay.update();
      visible.push(overlay.isRegistered());
    }
    expect({
      visible,
      widgets: widget.mock.calls.map(([key, factory]) => [key, typeof factory]),
      tasks: store.getState("visibility"),
    }).toStrictEqual({
      visible: [true, false, true],
      widgets: [
        ["rpiv-todos", "function"],
        ["rpiv-todos", "undefined"],
        ["rpiv-todos", "function"],
      ],
      tasks: state,
    });
  } finally {
    store.evictSession("visibility");
    store.clearActiveRenderSession();
    await fs.rm(directory, { recursive: true, force: true });
  }
});
