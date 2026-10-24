import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  provision,
  run,
  waitForSops,
  type Configuration,
  type Dependencies,
  type Specification,
} from "./provision.ts";

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
  it("waits for a new job to run and finish before accepting the secret files", async () => {
    const status = vi
      .fn()
      .mockResolvedValueOnce("")
      .mockResolvedValueOnce(
        "\tstate = not running\n\truns = 0\n\tlast exit code = 0\n",
      )
      .mockResolvedValueOnce("\tstate = running\n\truns = 1\n")
      .mockResolvedValue(
        "\tstate = not running\n\truns = 1\n\tlast exit code = 0\n",
      );
    const pause = vi.fn(async () => {});
    await waitForSops({ status, pause });
    expect(status).toHaveBeenCalledTimes(4);
    expect(pause).toHaveBeenCalledTimes(3);
  });

  it("rejects a failed decryption instead of using a previous key", async () => {
    await expect(
      waitForSops({
        status: async () =>
          "\tstate = not running\n\truns = 1\n\tlast exit code = 1\n",
        pause: async () => {},
      }),
    ).rejects.toThrow("sops-nix failed to decrypt secrets");
  });

  it("bounds the wait when the job never completes", async () => {
    const status = vi.fn(async () => "\tstate = running\n\truns = 1\n");
    await expect(
      waitForSops({ status, pause: async () => {} }),
    ).rejects.toThrow("Timed out");
    expect(status).toHaveBeenCalledTimes(50);
  });
});

describe.skipIf(!process.env.TEAMCLAUDE_CONFIG_MODULE)(
  "TeamClaude configuration writer",
  () => {
    let directory: string;

    afterEach(async () => {
      vi.unstubAllEnvs();
      if (directory) {
        await rm(directory, { recursive: true, force: true });
      }
    });

    async function files() {
      const configModule = process.env.TEAMCLAUDE_CONFIG_MODULE;
      if (!configModule) {
        throw new Error(
          "TEAMCLAUDE_CONFIG_MODULE must refer to the packaged configuration module",
        );
      }
      directory = await mkdtemp(join(tmpdir(), "teamclaude-provision-"));
      const config = join(directory, "teamclaude.json");
      const key = join(directory, "key");
      const manifest = join(directory, "provision.json");
      vi.stubEnv("TEAMCLAUDE_CONFIG", config);
      vi.stubEnv("TEAMROUTER_CONFIG", config);
      await writeFile(config, JSON.stringify(initial));
      await writeFile(key, "first-key\n");
      await writeFile(
        manifest,
        JSON.stringify({
          ...spec,
          apiKeyAccounts: { fallback: { apiKeyFile: key, priority: 100 } },
        }),
      );
      const notify = vi.fn(async () => {});
      return { configModule, config, key, manifest, notify };
    }

    it("persists key rotation with stable IDs, private permissions and unrelated fields", async () => {
      const { configModule, config, key, manifest, notify } = await files();
      await run(configModule, manifest, notify);
      const first: Configuration = JSON.parse(await readFile(config, "utf8"));
      await writeFile(key, "rotated-key\n");
      await run(configModule, manifest, notify);
      const expected = {
        ...initial,
        accounts: [
          oauth,
          { ...fallback, id: first.accounts[1]?.id, apiKey: "rotated-key" },
        ],
        proxy: { port: 3457, apiKey: "proxy-key" },
        switchThreshold: 0.9,
      };
      expect(JSON.parse(await readFile(config, "utf8"))).toStrictEqual(
        expected,
      );
      expect(first.accounts[1]?.id).toEqual(expect.any(String));
      expect((await stat(config)).mode & 0o777).toBe(0o600);
      expect(notify).toHaveBeenLastCalledWith(expected);
    });

    it.each([
      "not json with a secret",
      '{"accounts":[null]}',
      '{"proxy":{"port":"bad"}}',
    ])(
      "rejects malformed existing configuration without rewriting it: %s",
      async (invalid) => {
        const { configModule, config, manifest, notify } = await files();
        await writeFile(config, invalid);
        await expect(run(configModule, manifest, notify)).rejects.toThrow(
          "Invalid",
        );
        expect(await readFile(config, "utf8")).toBe(invalid);
        expect(notify).not.toHaveBeenCalled();
      },
    );

    it("rejects malformed account declarations before changing the configuration", async () => {
      const { configModule, config, manifest, notify } = await files();
      await writeFile(
        manifest,
        JSON.stringify({
          ...spec,
          apiKeyAccounts: { fallback: { apiKeyFile: 42 } },
        }),
      );
      await expect(run(configModule, manifest, notify)).rejects.toThrow(
        "Invalid provisioning specification",
      );
      expect(JSON.parse(await readFile(config, "utf8"))).toStrictEqual(initial);
    });

    it("reads the latest OAuth tokens after a competing writer releases the lock", async () => {
      const { configModule, config, manifest, notify } = await files();
      const library: {
        withConfigLock(
          path: string,
          operation: () => Promise<void>,
        ): Promise<void>;
      } = await import(pathToFileURL(configModule).href);
      const acquired = Promise.withResolvers<void>();
      const release = Promise.withResolvers<void>();
      const refreshed = {
        ...initial,
        accounts: [
          {
            ...oauth,
            accessToken: "newer-access",
            refreshToken: "newer-refresh",
          },
        ],
      };
      const writer = library.withConfigLock(config, async () => {
        acquired.resolve();
        await release.promise;
        await writeFile(config, JSON.stringify(refreshed));
      });
      await acquired.promise;
      const applying = run(configModule, manifest, notify);
      release.resolve();
      await Promise.all([writer, applying]);
      expect(JSON.parse(await readFile(config, "utf8"))).toStrictEqual({
        ...refreshed,
        accounts: [
          refreshed.accounts[0],
          { ...fallback, id: expect.any(String) },
        ],
        proxy: { port: 3457, apiKey: "proxy-key" },
        switchThreshold: 0.9,
      });
    });
  },
);
