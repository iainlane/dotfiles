import { dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";
import {
  AccountsSettingError,
  AmbiguousAccountPolicyError,
  ApiKeyAccountConflictError,
  ConfigurationWriteError,
  FileReadError,
  InvalidApiKeyError,
  InvalidDataError,
  InvalidJsonError,
  ReloadHttpError,
  ReloadTransportError,
  SopsDecryptionError,
  SopsTimeoutError,
  UnsupportedFieldError,
} from "./errors.ts";
import { main, type SystemDependencies } from "./provisioner.ts";

const configModule = "/teamclaude/src/config.js";
const configFile = "/runtime/teamclaude.json";
const specFile = "/nix/spec.json";
const keyFile = "/secrets/api-key";
const sopsProgram = "/nix/store/current-sops-nix-user";
const missingFile = Object.assign(new Error(), { code: "ENOENT" });
const deniedFile = Object.assign(new Error(), { code: "EACCES" });

const oauth = {
  id: "personal-id",
  name: "personal",
  type: "oauth",
  accessToken: "fresh-access",
  refreshToken: "fresh-refresh",
  expiresAt: 123,
};

const initial = {
  accounts: [oauth],
  proxy: { port: 3456, apiKey: "proxy-key" },
  switchThreshold: 0.98,
};

const spec = {
  settings: { switchThreshold: 0.9, proxy: { port: 3457 } },
  apiKeyAccounts: {
    fallback: { apiKeyFile: keyFile, priority: 100 },
  },
};

const fallback = {
  name: "fallback",
  type: "apikey",
  apiKey: "first-key",
  priority: 100,
  dotfilesManaged: true,
};

const provisioned = {
  accounts: [oauth, { ...fallback, id: "generated-id" }],
  proxy: { port: 3457, apiKey: "proxy-key" },
  switchThreshold: 0.9,
};

function sopsStatus(
  program: string,
  state: string,
  runs: number,
  exit?: number,
) {
  return `\tprogram = ${program}\n\tstate = ${state}\n\truns = ${runs}\n${exit === undefined ? "" : `\tlast exit code = ${exit}\n`}`;
}

/**
 * A machine with the files, TeamClaude modules, sops-nix job and proxy that
 * the provisioner uses. The clock moves only when the provisioner pauses.
 */
function fixture(
  options: {
    config?: unknown;
    spec?: unknown;
    key?: string;
    defaultConfig?: unknown;
  } = {},
) {
  let time = 0;
  let started = 0;
  const files = new Map<string, { content: string; modified: number }>();
  const directories = new Set(["/nix", "/secrets"]);
  const denied = new Set<string>();
  const scheduled: { delay: number; apply: () => void }[] = [];
  const timeline: { at: number; apply: () => void }[] = [];
  const write = (path: string, content: string) => {
    if (!directories.has(dirname(path))) {
      throw missingFile;
    }
    files.set(path, { content, modified: time });
  };
  const machine = {
    sops: { status: "" },
    proxy: {
      port: 3457,
      apiKey: "proxy-key",
      running: true,
      failure: undefined as Error | undefined,
      loaded: undefined as unknown,
    },
    writeFailure: undefined as Error | undefined,
    lockHolder: undefined as (() => void) | undefined,
  };

  if (options.config !== null) {
    directories.add(dirname(configFile));
    write(configFile, JSON.stringify(options.config ?? initial));
  }
  write(specFile, JSON.stringify(options.spec ?? spec));
  write(keyFile, options.key ?? "first-key\n");

  const library = {
    createDefaultConfig: () =>
      structuredClone(options.defaultConfig ?? { accounts: [] }),
    withConfigLock: async <T>(path: string, update: () => Promise<T>) => {
      if (path === configFile) {
        machine.lockHolder?.();
        machine.lockHolder = undefined;
      }
      return update();
    },
    writeJsonAtomic: async (path: string, value: unknown) => {
      if (machine.writeFailure) {
        throw machine.writeFailure;
      }
      write(path, JSON.stringify(value));
    },
    getConfigPath: () => configFile,
  };
  const accountIds = {
    ensureAccountIds: (accounts: { id?: string }[]) => {
      for (const account of accounts) {
        account.id ??= "generated-id";
      }
    },
  };
  const libraryUrl = pathToFileURL(configModule);

  const system: SystemDependencies = {
    readText: async (path) => {
      if (denied.has(path)) {
        throw deniedFile;
      }
      const file = files.get(path);
      if (file === undefined) {
        throw missingFile;
      }
      return file.content;
    },
    prepareDirectory: async (path) => {
      directories.add(path);
    },
    importModule: async (url) => {
      if (url === libraryUrl.href) {
        return library;
      }
      if (url === new URL("./account-id.js", libraryUrl).href) {
        return accountIds;
      }
      throw new Error(`Cannot find module ${url}`);
    },
    sopsStatus: async () => machine.sops.status,
    clock: {
      now: () => time,
      pause: async () => {
        time += 100;
        for (const event of timeline.filter(({ at }) => at <= time)) {
          timeline.splice(timeline.indexOf(event), 1);
          event.apply();
        }
      },
    },
    requestReload: async (url, apiKey) => {
      const { proxy } = machine;
      if (proxy.failure) {
        throw proxy.failure;
      }
      const target = new URL(url);
      if (!proxy.running || target.port !== String(proxy.port)) {
        throw new TypeError("fetch failed", {
          cause: { code: "ECONNREFUSED" },
        });
      }
      if (target.pathname !== "/teamclaude/reload") {
        return { ok: false, status: 404 };
      }
      if (apiKey !== proxy.apiKey) {
        return { ok: false, status: 401 };
      }
      proxy.loaded = JSON.parse(files.get(configFile)?.content ?? "null");
      return { ok: true, status: 200 };
    },
  };

  return Object.assign(machine, {
    files,
    directories,
    denied,
    write,
    /** Runs `apply` once the clock reaches `delay` milliseconds into the next run. */
    after: (delay: number, apply: () => void) => {
      scheduled.push({ delay, apply });
    },
    /** Runs the provisioner one second after the previous run started. */
    run: async (args: string[] = [configModule, specFile]) => {
      time += 1000;
      started = time;
      for (const { delay, apply } of scheduled.splice(0)) {
        timeline.push({ at: started + delay, apply });
      }
      await main(args, system);
    },
    elapsed: () => time - started,
    stored: () => {
      const file = files.get(configFile);
      if (file === undefined) {
        return null;
      }
      const config: unknown = JSON.parse(file.content);
      return { config, modified: file.modified };
    },
  });
}

const unchanged = (config: unknown) => ({ config, modified: 0 });

describe("TeamClaude provisioning", () => {
  it("merges settings and API accounts while preserving OAuth credentials", async () => {
    const f = fixture();

    await f.run();

    expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
      stored: { config: provisioned, modified: 1000 },
      loaded: provisioned,
    });
  });

  it("rotates a key without changing its account ID or runtime settings", async () => {
    const f = fixture({
      config: {
        ...initial,
        accounts: [
          oauth,
          {
            ...fallback,
            id: "api-id",
            accessToken: "stale-key",
            disabled: true,
          },
        ],
      },
      key: "rotated-key",
    });

    await f.run();

    expect(f.stored()).toStrictEqual({
      config: {
        accounts: [
          oauth,
          { ...fallback, id: "api-id", apiKey: "rotated-key", disabled: true },
        ],
        proxy: { port: 3457, apiKey: "proxy-key" },
        switchThreshold: 0.9,
      },
      modified: 1000,
    });
  });

  it.each([true, false])(
    "reconciles account policy %s without replacing credentials",
    async (enabled) => {
      const f = fixture({
        config: {
          ...initial,
          accounts: [
            {
              ...oauth,
              allowExtraUsage: !enabled,
              preferExtraUsage: !enabled,
            },
            { ...fallback, disabled: true },
          ],
        },
        spec: {
          ...spec,
          accountSettings: {
            personal: { allowExtraUsage: enabled, preferExtraUsage: enabled },
          },
        },
      });

      await f.run();
      await f.run();

      expect(f.stored()).toStrictEqual({
        config: {
          accounts: [
            {
              ...oauth,
              allowExtraUsage: enabled,
              preferExtraUsage: enabled,
            },
            { ...fallback, id: "generated-id", disabled: true },
          ],
          proxy: { port: 3457, apiKey: "proxy-key" },
          switchThreshold: 0.9,
        },
        modified: 1000,
      });
    },
  );

  it("waits for login before applying policy to a missing account", async () => {
    const f = fixture({
      spec: {
        settings: {},
        apiKeyAccounts: {},
        accountSettings: { missing: { allowExtraUsage: true } },
      },
    });
    f.proxy.port = 3456;

    await f.run();

    expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
      stored: unchanged(initial),
      loaded: initial,
    });
  });

  it("rejects an ambiguous account policy without writing", async () => {
    const config = { ...initial, accounts: [oauth, { ...oauth, id: "other" }] };
    const f = fixture({
      config,
      spec: {
        settings: {},
        apiKeyAccounts: {},
        accountSettings: { personal: { allowExtraUsage: true } },
      },
    });

    await expect(f.run()).rejects.toStrictEqual(
      new AmbiguousAccountPolicyError("personal"),
    );

    expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
      stored: unchanged(config),
      loaded: undefined,
    });
  });

  it("creates the initial configuration through the same reconciliation", async () => {
    const f = fixture({
      config: null,
      defaultConfig: { ...initial, accounts: [] },
    });

    await f.run();

    expect(f.stored()).toStrictEqual({
      config: {
        accounts: [{ ...fallback, id: "generated-id" }],
        proxy: { port: 3457, apiKey: "proxy-key" },
        switchThreshold: 0.9,
      },
      modified: 1000,
    });
  });

  it("does not rewrite an unchanged configuration and retries its reload", async () => {
    const f = fixture({ config: provisioned });

    await f.run();

    expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
      stored: unchanged(provisioned),
      loaded: provisioned,
    });
  });

  it("removes only API accounts previously managed by Nix", async () => {
    const manual = { name: "manual", type: "apikey", apiKey: "manual-key" };
    const f = fixture({
      config: { ...initial, accounts: [oauth, fallback, manual] },
      spec: { settings: {}, apiKeyAccounts: {} },
    });
    f.proxy.port = 3456;

    await f.run();

    expect(f.stored()).toStrictEqual({
      config: {
        ...initial,
        accounts: [oauth, { ...manual, id: "generated-id" }],
      },
      modified: 1000,
    });
  });

  it.each(["", "\n", "multiple keys"])(
    "rejects an invalid key %j without writing",
    async (key) => {
      const f = fixture({ key });

      await expect(f.run()).rejects.toStrictEqual(
        new InvalidApiKeyError(keyFile),
      );

      expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
        stored: unchanged(initial),
        loaded: undefined,
      });
    },
  );

  it("does not write when a secret cannot be read", async () => {
    const f = fixture();
    f.denied.add(keyFile);

    await expect(f.run()).rejects.toStrictEqual(
      new FileReadError(keyFile, { cause: deniedFile }),
    );

    expect(f.stored()).toStrictEqual(unchanged(initial));
  });

  it.each([
    { accounts: [oauth, { ...oauth, name: "fallback" }] },
    { accounts: [oauth, fallback, { ...fallback }] },
  ])(
    "rejects conflicting accounts without modifying runtime state",
    async ({ accounts }) => {
      const config = { ...initial, accounts };
      const f = fixture({ config });

      await expect(f.run()).rejects.toStrictEqual(
        new ApiKeyAccountConflictError("fallback"),
      );

      expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
        stored: unchanged(config),
        loaded: undefined,
      });
    },
  );

  it("does not create a configuration when nothing is declared", async () => {
    const f = fixture({
      config: null,
      spec: { settings: {}, apiKeyAccounts: {} },
    });

    await f.run();

    expect(f.stored()).toBeNull();
  });

  it("refuses to manage OAuth credentials through settings", async () => {
    const f = fixture({ spec: { ...spec, settings: { accounts: [] } } });

    await expect(f.run()).rejects.toStrictEqual(new AccountsSettingError());

    expect(f.stored()).toStrictEqual(unchanged(initial));
  });

  it.each(["constructor", "prototype"])(
    "rejects unsafe configuration field %s without writing",
    async (field) => {
      const f = fixture({ spec: { ...spec, settings: { [field]: true } } });

      await expect(f.run()).rejects.toStrictEqual(
        new UnsupportedFieldError(field),
      );

      expect(f.stored()).toStrictEqual(unchanged(initial));
    },
  );

  it("drops a __proto__ setting while validating the specification", async () => {
    const f = fixture({
      spec: { ...spec, settings: { ...spec.settings, ["__proto__"]: true } },
    });

    await f.run();

    expect(f.stored()).toStrictEqual({ config: provisioned, modified: 1000 });
  });
});

describe("sops-nix decryption", () => {
  const sopsArgs = ["--sops-program", sopsProgram, configModule, specFile];
  const decrypted = {
    ...provisioned,
    accounts: [
      oauth,
      { ...fallback, id: "generated-id", apiKey: "decrypted-key" },
    ],
  };

  it("ignores historical success from a previous secret generation", async () => {
    const f = fixture({ key: "previous-key" });
    f.sops.status = sopsStatus(
      "/nix/store/previous-sops-nix-user",
      "not running",
      3,
      0,
    );
    f.after(100, () => {
      f.sops.status = sopsStatus(sopsProgram, "running", 1);
    });
    f.after(200, () => {
      f.write(keyFile, "decrypted-key");
      f.sops.status = sopsStatus(sopsProgram, "not running", 1, 0);
    });

    await f.run(sopsArgs);

    expect({ elapsed: f.elapsed(), loaded: f.proxy.loaded }).toStrictEqual({
      elapsed: 200,
      loaded: decrypted,
    });
  });

  it("recognises the expected script through Home Manager's store-mount wrapper", async () => {
    const f = fixture({ key: "decrypted-key" });
    f.sops.status = `\tprogram = /bin/sh\n\targuments = {\n\t\t/bin/sh\n\t\t-c\n\t\t/bin/wait4path /nix/store && exec ${sopsProgram}\n\t}\n\tstate = not running\n\truns = 1\n\tlast exit code = 0\n`;

    await f.run(sopsArgs);

    expect({ elapsed: f.elapsed(), loaded: f.proxy.loaded }).toStrictEqual({
      elapsed: 0,
      loaded: decrypted,
    });
  });

  it("waits for a new job to run and finish before accepting the secret files", async () => {
    const f = fixture({ key: "previous-key" });
    f.after(100, () => {
      f.sops.status = sopsStatus(sopsProgram, "not running", 0, 0);
    });
    f.after(200, () => {
      f.sops.status = "\tstate = running\n\truns = 1\n";
    });
    f.after(300, () => {
      f.write(keyFile, "decrypted-key");
      f.sops.status = sopsStatus(sopsProgram, "not running", 1, 0);
    });

    await f.run(sopsArgs);

    expect({ elapsed: f.elapsed(), loaded: f.proxy.loaded }).toStrictEqual({
      elapsed: 300,
      loaded: decrypted,
    });
  });

  it("rejects a failed decryption instead of using a previous key", async () => {
    const f = fixture({ key: "previous-key" });
    f.sops.status = sopsStatus(sopsProgram, "not running", 1, 1);

    await expect(f.run(sopsArgs)).rejects.toStrictEqual(
      new SopsDecryptionError(sopsProgram),
    );

    expect(f.stored()).toStrictEqual(unchanged(initial));
  });

  it("bounds the wait when the job never completes", async () => {
    const f = fixture();
    f.sops.status = "\tstate = running\n\truns = 1\n";

    await expect(f.run(sopsArgs)).rejects.toStrictEqual(
      new SopsTimeoutError(sopsProgram),
    );

    expect({ elapsed: f.elapsed(), stored: f.stored() }).toStrictEqual({
      elapsed: 5000,
      stored: unchanged(initial),
    });
  });
});

describe("provisioning adapters", () => {
  it("uses supplied paths and preserves IDs across key rotation", async () => {
    const f = fixture();

    await f.run();
    f.write(keyFile, "rotated-key\n");

    await f.run();
    const expected = {
      ...provisioned,
      accounts: [
        oauth,
        { ...fallback, id: "generated-id", apiKey: "rotated-key" },
      ],
    };

    expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
      stored: { config: expected, modified: 2000 },
      loaded: expected,
    });
  });

  it("does not write an unchanged configuration", async () => {
    const f = fixture();

    await f.run();
    f.proxy.loaded = undefined;

    await f.run();

    expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
      stored: { config: provisioned, modified: 1000 },
      loaded: provisioned,
    });
  });

  it("uses the supplied default when the configuration is absent", async () => {
    const f = fixture({ config: null });
    f.proxy.running = false;

    await f.run();

    expect(f.stored()).toStrictEqual({
      config: {
        accounts: [{ ...fallback, id: "generated-id" }],
        proxy: { port: 3457 },
        switchThreshold: 0.9,
      },
      modified: 1000,
    });
  });

  it.each([
    {
      invalid: "not json with a secret",
      failure: new InvalidJsonError(configFile),
    },
    {
      invalid: '{"accounts":[null]}',
      failure: new InvalidDataError("configuration", configFile, [
        ["accounts", 0],
      ]),
    },
    {
      invalid: '{"proxy":{"port":"bad"}}',
      failure: new InvalidDataError("configuration", configFile, [
        ["proxy", "port"],
      ]),
    },
  ])(
    "rejects malformed configuration without rewriting it: $invalid",
    async ({ invalid, failure }) => {
      const f = fixture();
      f.write(configFile, invalid);

      await expect(f.run()).rejects.toStrictEqual(failure);

      expect({
        file: f.files.get(configFile),
        loaded: f.proxy.loaded,
      }).toStrictEqual({
        file: { content: invalid, modified: 0 },
        loaded: undefined,
      });
    },
  );

  it("validates declarations before accessing the runtime configuration", async () => {
    const f = fixture({
      spec: { ...spec, apiKeyAccounts: { fallback: { apiKeyFile: 42 } } },
    });
    f.write(configFile, "not json");

    await expect(f.run()).rejects.toStrictEqual(
      new InvalidDataError("specification", specFile, [
        ["apiKeyAccounts", "fallback", "apiKeyFile"],
        ["apiKeyAccounts", "fallback", "priority"],
      ]),
    );
  });

  it("reads refreshed OAuth credentials only after acquiring the lock", async () => {
    const f = fixture();
    const refreshed = {
      ...oauth,
      accessToken: "newer-access",
      refreshToken: "newer-refresh",
    };
    f.lockHolder = () => {
      f.write(
        configFile,
        JSON.stringify({ ...initial, accounts: [refreshed] }),
      );
    };

    await f.run();

    expect(f.stored()?.config).toStrictEqual({
      ...provisioned,
      accounts: [refreshed, { ...fallback, id: "generated-id" }],
    });
  });

  it("retries an unavailable secret through the supplied clock", async () => {
    const f = fixture();
    f.files.delete(keyFile);
    f.after(100, () => f.write(keyFile, "decrypted-key"));

    await f.run();

    expect({ elapsed: f.elapsed(), loaded: f.proxy.loaded }).toStrictEqual({
      elapsed: 100,
      loaded: {
        ...provisioned,
        accounts: [
          oauth,
          { ...fallback, id: "generated-id", apiKey: "decrypted-key" },
        ],
      },
    });
  });

  it("bounds secret retries without a real timer", async () => {
    const f = fixture();
    f.files.delete(keyFile);

    await expect(f.run()).rejects.toStrictEqual(
      new FileReadError(keyFile, { cause: missingFile }),
    );

    expect({ elapsed: f.elapsed(), stored: f.stored() }).toStrictEqual({
      elapsed: 5000,
      stored: unchanged(initial),
    });
  });

  it("propagates non-missing read errors without retrying", async () => {
    const f = fixture();
    f.denied.add(keyFile);

    await expect(f.run()).rejects.toStrictEqual(
      new FileReadError(keyFile, { cause: deniedFile }),
    );

    expect(f.elapsed()).toBe(0);
  });

  it("preserves the configuration when its atomic write fails", async () => {
    const f = fixture();
    f.writeFailure = deniedFile;

    await expect(f.run()).rejects.toStrictEqual(
      new ConfigurationWriteError(configFile, { cause: deniedFile }),
    );

    expect({ stored: f.stored(), loaded: f.proxy.loaded }).toStrictEqual({
      stored: unchanged(initial),
      loaded: undefined,
    });
  });
});

describe("proxy reload", () => {
  const nothingDeclared = { settings: {}, apiKeyAccounts: {} };

  it("sends the configured endpoint and API key to the supplied transport", async () => {
    const f = fixture({ spec: nothingDeclared });
    f.proxy.port = 3456;

    await f.run();

    expect(f.proxy.loaded).toStrictEqual(initial);
  });

  it("skips the request when the proxy has no port", async () => {
    const f = fixture({ config: { accounts: [] }, spec: nothingDeclared });

    await expect(f.run()).resolves.toBeUndefined();
  });

  it("accepts a stopped proxy", async () => {
    const f = fixture();
    f.proxy.running = false;

    await expect(f.run()).resolves.toBeUndefined();
  });

  it("reports an unsuccessful HTTP response", async () => {
    const f = fixture();
    f.proxy.apiKey = "other-key";

    await expect(f.run()).rejects.toStrictEqual(new ReloadHttpError(401));
  });

  it("propagates other transport errors", async () => {
    const f = fixture();
    const cause = new DOMException("", "TimeoutError");
    f.proxy.failure = cause;

    await expect(f.run()).rejects.toStrictEqual(
      new ReloadTransportError({ cause }),
    );
  });
});
