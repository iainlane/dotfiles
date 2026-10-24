import { describe, expect, it, vi } from "vitest";
import {
  provision,
  run,
  waitForSops,
  reload,
  type RuntimeDependencies,
  type Configuration,
  type Dependencies,
  type Specification,
} from "./provision.ts";

const sopsProgram = "/nix/store/current-sops-nix-user";

const oauth = {
  id: "personal-id",
  name: "personal",
  type: "oauth",
  accessToken: "fresh-access",
  refreshToken: "fresh-refresh",
  expiresAt: 123,
};

const initial: Configuration = {
  accounts: [oauth],
  proxy: { port: 3456, apiKey: "proxy-key" },
  switchThreshold: 0.98,
};

const spec: Specification = {
  settings: { switchThreshold: 0.9, proxy: { port: 3457 } },
  apiKeyAccounts: {
    fallback: { apiKeyFile: "/secrets/api-key", priority: 100 },
  },
};

const fallback = {
  name: "fallback",
  type: "apikey",
  apiKey: "first-key",
  priority: 100,
  dotfilesManaged: true,
};

function fixture(current: Configuration | null = initial) {
  const state = { config: structuredClone(current), writes: 0 };

  const dependencies: Dependencies = {
    readKey: vi.fn(async () => "first-key\n"),
    defaultConfig: () => ({ ...structuredClone(initial), accounts: [] }),
    update: async (change) => {
      const updated = change(state.config);

      if (updated && JSON.stringify(updated) !== JSON.stringify(state.config)) {
        state.config = updated;
        state.writes += 1;
      }

      return updated;
    },
    reload: vi.fn(async () => {}),
  };

  return { state, dependencies };
}

describe("TeamClaude provisioning", () => {
  it("merges settings and API accounts while preserving OAuth credentials", async () => {
    const { state, dependencies } = fixture();

    await provision(spec, dependencies);

    const expected = {
      accounts: [oauth, fallback],
      proxy: { port: 3457, apiKey: "proxy-key" },
      switchThreshold: 0.9,
    };

    expect(state).toStrictEqual({ config: expected, writes: 1 });

    expect(dependencies.readKey).toHaveBeenCalledExactlyOnceWith(
      "/secrets/api-key",
    );

    expect(dependencies.reload).toHaveBeenCalledExactlyOnceWith(expected);
  });

  it("rotates a key without changing its account ID or runtime settings", async () => {
    const { state, dependencies } = fixture({
      ...initial,
      accounts: [
        oauth,
        { ...fallback, id: "api-id", accessToken: "stale-key", disabled: true },
      ],
    });
    dependencies.readKey = async () => "rotated-key";

    await provision(spec, dependencies);

    expect(state).toStrictEqual({
      config: {
        accounts: [
          oauth,
          { ...fallback, id: "api-id", apiKey: "rotated-key", disabled: true },
        ],
        proxy: { port: 3457, apiKey: "proxy-key" },
        switchThreshold: 0.9,
      },
      writes: 1,
    });
  });

  it("creates the initial configuration through the same reconciliation", async () => {
    const { state, dependencies } = fixture(null);

    await provision(spec, dependencies);

    expect(state).toStrictEqual({
      config: {
        accounts: [fallback],
        proxy: { port: 3457, apiKey: "proxy-key" },
        switchThreshold: 0.9,
      },
      writes: 1,
    });
  });

  it("does not rewrite an unchanged configuration and retries its reload", async () => {
    const { state, dependencies } = fixture();

    await provision(spec, dependencies);
    state.writes = 0;
    vi.mocked(dependencies.reload).mockClear();
    const expected = structuredClone(state.config);

    await provision(spec, dependencies);

    expect(state).toStrictEqual({ config: expected, writes: 0 });

    expect(dependencies.reload).toHaveBeenCalledExactlyOnceWith(expected);
  });

  it("removes only API accounts previously managed by Nix", async () => {
    const manual = { name: "manual", type: "apikey", apiKey: "manual-key" };
    const { state, dependencies } = fixture({
      ...initial,
      accounts: [oauth, fallback, manual],
    });

    await provision({ settings: {}, apiKeyAccounts: {} }, dependencies);

    expect(state).toStrictEqual({
      config: { ...initial, accounts: [oauth, manual] },
      writes: 1,
    });
  });

  it.each(["", "\n", "multiple keys"])(
    "rejects an invalid key %j without writing",
    async (key) => {
      const { state, dependencies } = fixture();
      dependencies.readKey = async () => key;

      await expect(provision(spec, dependencies)).rejects.toThrow(
        "Expected a single API key",
      );

      expect(state).toStrictEqual({ config: initial, writes: 0 });

      expect(dependencies.reload).not.toHaveBeenCalled();
    },
  );

  it("does not write when a secret cannot be read", async () => {
    const { state, dependencies } = fixture();
    dependencies.readKey = async () => {
      throw new Error("Secret unavailable");
    };

    await expect(provision(spec, dependencies)).rejects.toThrow(
      "Secret unavailable",
    );

    expect(state).toStrictEqual({ config: initial, writes: 0 });
  });

  it.each([
    { accounts: [oauth, { ...oauth, name: "fallback" }] },
    { accounts: [oauth, fallback, { ...fallback }] },
  ])(
    "rejects conflicting accounts without modifying runtime state",
    async ({ accounts }) => {
      const config = { ...initial, accounts };
      const { state, dependencies } = fixture(config);

      await expect(provision(spec, dependencies)).rejects.toThrow(
        "conflicts with existing accounts",
      );

      expect(state).toStrictEqual({ config, writes: 0 });
    },
  );

  it("does not create a configuration when nothing is declared", async () => {
    const { state, dependencies } = fixture(null);

    await provision({ settings: {}, apiKeyAccounts: {} }, dependencies);

    expect(state).toStrictEqual({ config: null, writes: 0 });
  });

  it("refuses to manage OAuth credentials through settings", async () => {
    const { state, dependencies } = fixture();

    await expect(
      provision({ ...spec, settings: { accounts: [] } }, dependencies),
    ).rejects.toThrow("Declare accounts through apiKeyAccounts");

    expect(state).toStrictEqual({ config: initial, writes: 0 });
  });
});

describe("sops-nix decryption", () => {
  it("ignores historical success from a previous secret generation", async () => {
    const status = vi
      .fn()
      .mockResolvedValueOnce(
        "\tprogram = /nix/store/previous-sops-nix-user\n\tstate = not running\n\truns = 3\n\tlast exit code = 0\n",
      )
      .mockResolvedValueOnce(
        `\tprogram = ${sopsProgram}\n\tstate = running\n\truns = 1\n`,
      )
      .mockResolvedValue(
        `\tprogram = ${sopsProgram}\n\tstate = not running\n\truns = 1\n\tlast exit code = 0\n`,
      );
    const pause = vi.fn(async () => {});

    await waitForSops(sopsProgram, { status, pause });

    expect(status).toHaveBeenCalledTimes(3);

    expect(pause).toHaveBeenCalledTimes(2);
  });

  it("recognises the expected script through Home Manager's store-mount wrapper", async () => {
    const pause = vi.fn(async () => {});

    await waitForSops(sopsProgram, {
      status: async () =>
        `\tprogram = /bin/sh\n\targuments = {\n\t\t/bin/sh\n\t\t-c\n\t\t/bin/wait4path /nix/store && exec ${sopsProgram}\n\t}\n\tstate = not running\n\truns = 1\n\tlast exit code = 0\n`,
      pause,
    });

    expect(pause).not.toHaveBeenCalled();
  });

  it("waits for a new job to run and finish before accepting the secret files", async () => {
    const status = vi
      .fn()
      .mockResolvedValueOnce("")
      .mockResolvedValueOnce(
        `\tprogram = ${sopsProgram}\n\tstate = not running\n\truns = 0\n\tlast exit code = 0\n`,
      )
      .mockResolvedValueOnce("\tstate = running\n\truns = 1\n")
      .mockResolvedValue(
        `\tprogram = ${sopsProgram}\n\tstate = not running\n\truns = 1\n\tlast exit code = 0\n`,
      );
    const pause = vi.fn(async () => {});

    await waitForSops(sopsProgram, { status, pause });

    expect(status).toHaveBeenCalledTimes(4);

    expect(pause).toHaveBeenCalledTimes(3);
  });

  it("rejects a failed decryption instead of using a previous key", async () => {
    await expect(
      waitForSops(sopsProgram, {
        status: async () =>
          `\tprogram = ${sopsProgram}\n\tstate = not running\n\truns = 1\n\tlast exit code = 1\n`,
        pause: async () => {},
      }),
    ).rejects.toThrow("sops-nix failed to decrypt secrets");
  });

  it("bounds the wait when the job never completes", async () => {
    const status = vi.fn(async () => "\tstate = running\n\truns = 1\n");

    await expect(
      waitForSops(sopsProgram, { status, pause: async () => {} }),
    ).rejects.toThrow("Timed out");

    expect(status).toHaveBeenCalledTimes(50);
  });
});

const paths = {
  configFile: "/runtime/teamclaude.json",
  specFile: "/nix/spec.json",
};

function runtimeFixture() {
  const files = new Map([
    [paths.configFile, JSON.stringify(initial)],
    [paths.specFile, JSON.stringify(spec)],
    ["/secrets/api-key", "first-key\n"],
  ]);

  let time = 0;

  const dependencies: RuntimeDependencies = {
    readText: vi.fn(async (path) => {
      const content = files.get(path);
      if (content === undefined) {
        throw Object.assign(new Error("File unavailable"), { code: "ENOENT" });
      }
      return content;
    }),
    prepareDirectory: vi.fn(async () => {}),
    library: {
      createDefaultConfig: () => ({ accounts: [] }),
      withConfigLock: vi.fn(async (_path, update) => update()),
      writeJsonAtomic: vi.fn(async (path, config) => {
        files.set(path, JSON.stringify(config));
      }),
    },
    ensureAccountIds: (accounts) => {
      for (const account of accounts) {
        account.id ??= "generated-id";
      }
    },
    clock: {
      now: () => time,
      pause: vi.fn(async () => {
        time += 100;
      }),
    },
    reload: vi.fn(async () => {}),
  };

  return { files, dependencies };
}

describe("provisioning adapters", () => {
  it("uses supplied paths and preserves IDs across key rotation", async () => {
    const { files, dependencies } = runtimeFixture();

    await run(paths, dependencies);
    files.set("/secrets/api-key", "rotated-key\n");

    await run(paths, dependencies);
    const expected = {
      ...initial,
      accounts: [
        oauth,
        { ...fallback, id: "generated-id", apiKey: "rotated-key" },
      ],
      proxy: { port: 3457, apiKey: "proxy-key" },
      switchThreshold: 0.9,
    };

    expect(JSON.parse(files.get(paths.configFile) ?? "null")).toStrictEqual(
      expected,
    );

    expect(dependencies.library.writeJsonAtomic).toHaveBeenLastCalledWith(
      paths.configFile,
      expected,
    );

    expect(dependencies.prepareDirectory).toHaveBeenCalledWith("/runtime");

    expect(dependencies.reload).toHaveBeenLastCalledWith(expected);
  });

  it("does not write an unchanged configuration", async () => {
    const { dependencies } = runtimeFixture();

    await run(paths, dependencies);
    vi.mocked(dependencies.library.writeJsonAtomic).mockClear();

    await run(paths, dependencies);

    expect(dependencies.library.writeJsonAtomic).not.toHaveBeenCalled();

    expect(dependencies.reload).toHaveBeenCalledTimes(2);
  });

  it("uses the supplied default when the configuration is absent", async () => {
    const { files, dependencies } = runtimeFixture();
    files.delete(paths.configFile);

    await run(paths, dependencies);

    expect(JSON.parse(files.get(paths.configFile) ?? "null")).toStrictEqual({
      accounts: [{ ...fallback, id: "generated-id" }],
      proxy: { port: 3457 },
      switchThreshold: 0.9,
    });
  });

  it.each([
    "not json with a secret",
    '{"accounts":[null]}',
    '{"proxy":{"port":"bad"}}',
  ])(
    "rejects malformed configuration without rewriting it: %s",
    async (invalid) => {
      const { files, dependencies } = runtimeFixture();
      files.set(paths.configFile, invalid);

      await expect(run(paths, dependencies)).rejects.toThrow("Invalid");

      expect(files.get(paths.configFile)).toBe(invalid);

      expect(dependencies.library.writeJsonAtomic).not.toHaveBeenCalled();

      expect(dependencies.reload).not.toHaveBeenCalled();
    },
  );

  it("validates declarations before accessing the runtime configuration", async () => {
    const { files, dependencies } = runtimeFixture();
    files.set(
      paths.specFile,
      JSON.stringify({
        ...spec,
        apiKeyAccounts: { fallback: { apiKeyFile: 42 } },
      }),
    );

    await expect(run(paths, dependencies)).rejects.toThrow(
      "Invalid provisioning specification",
    );

    expect(dependencies.readText).toHaveBeenCalledExactlyOnceWith(
      paths.specFile,
    );

    expect(dependencies.prepareDirectory).not.toHaveBeenCalled();
  });

  it("reads refreshed OAuth credentials only after acquiring the lock", async () => {
    const { files, dependencies } = runtimeFixture();
    const refreshed = {
      ...oauth,
      accessToken: "newer-access",
      refreshToken: "newer-refresh",
    };
    dependencies.library.withConfigLock = async (path, update) => {
      expect(path).toBe(paths.configFile);

      expect(dependencies.readText).not.toHaveBeenCalledWith(paths.configFile);
      files.set(path, JSON.stringify({ ...initial, accounts: [refreshed] }));
      return update();
    };

    await run(paths, dependencies);

    expect(JSON.parse(files.get(paths.configFile) ?? "null")).toStrictEqual({
      accounts: [refreshed, { ...fallback, id: "generated-id" }],
      proxy: { port: 3457, apiKey: "proxy-key" },
      switchThreshold: 0.9,
    });
  });

  it("retries an unavailable secret through the supplied clock", async () => {
    const { files, dependencies } = runtimeFixture();
    files.delete("/secrets/api-key");
    dependencies.clock.pause = vi.fn(async () => {
      files.set("/secrets/api-key", "decrypted-key");
    });

    await run(paths, dependencies);

    expect(dependencies.clock.pause).toHaveBeenCalledTimes(1);

    expect(dependencies.reload).toHaveBeenCalledExactlyOnceWith({
      accounts: [
        oauth,
        { ...fallback, id: "generated-id", apiKey: "decrypted-key" },
      ],
      proxy: { port: 3457, apiKey: "proxy-key" },
      switchThreshold: 0.9,
    });
  });

  it("bounds secret retries without a real timer", async () => {
    const { files, dependencies } = runtimeFixture();
    files.delete("/secrets/api-key");

    await expect(run(paths, dependencies)).rejects.toThrow("File unavailable");

    expect(dependencies.clock.pause).toHaveBeenCalledTimes(50);

    expect(dependencies.library.writeJsonAtomic).not.toHaveBeenCalled();
  });

  it("propagates non-missing read errors without retrying", async () => {
    const { dependencies } = runtimeFixture();
    dependencies.readText = async (path) => {
      if (path === paths.specFile) {
        return JSON.stringify(spec);
      }
      throw Object.assign(new Error("Permission denied"), { code: "EACCES" });
    };

    await expect(run(paths, dependencies)).rejects.toThrow("Permission denied");

    expect(dependencies.clock.pause).not.toHaveBeenCalled();
  });
});

describe("proxy reload", () => {
  it("sends the configured endpoint and API key to the supplied transport", async () => {
    const request = vi.fn(async () => ({ ok: true, status: 200 }));
    await reload(initial, request);

    expect(request).toHaveBeenCalledExactlyOnceWith(
      "http://127.0.0.1:3456/teamclaude/reload",
      "proxy-key",
    );
  });

  it("skips the request when the proxy has no port", async () => {
    const request = vi.fn(async () => ({ ok: true, status: 200 }));
    await reload({ accounts: [] }, request);

    expect(request).not.toHaveBeenCalled();
  });

  it("accepts a stopped proxy", async () => {
    await expect(
      reload(initial, async () => {
        throw new Error("Connection failed", {
          cause: { code: "ECONNREFUSED" },
        });
      }),
    ).resolves.toBeUndefined();
  });

  it("reports an unsuccessful HTTP response", async () => {
    await expect(
      reload(initial, async () => ({ ok: false, status: 401 })),
    ).rejects.toThrow("reload returned 401");
  });

  it("propagates other transport errors", async () => {
    await expect(
      reload(initial, async () => {
        throw new Error("Request timed out");
      }),
    ).rejects.toThrow("Request timed out");
  });
});
