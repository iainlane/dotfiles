import { dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { z } from "zod";
import {
  AccountsSettingError,
  AmbiguousAccountPolicyError,
  ApiKeyAccountConflictError,
  ConfigurationWriteError,
  FileReadError,
  InvalidApiKeyError,
  InvalidArgumentsError,
  InvalidDataError,
  InvalidJsonError,
  ProvisionError,
  ReloadHttpError,
  ReloadTransportError,
  SopsDecryptionError,
  SopsTimeoutError,
  UnsupportedFieldError,
  type ValidationSource,
} from "./errors.ts";

const objectSchema = z.record(z.string(), z.unknown());

const accountSchema = z.looseObject({
  name: z.string().optional(),
  type: z.string().optional(),
  dotfilesManaged: z.boolean().optional(),
});

const configurationSchema = z.looseObject({
  accounts: z.array(accountSchema).default([]),
  proxy: z
    .looseObject({
      port: z.int().min(1).max(65535).optional(),
      apiKey: z.string().optional(),
    })
    .optional(),
});

const specificationSchema = z.object({
  settings: z.record(z.string(), z.json()),
  apiKeyAccounts: z.record(
    z.string(),
    z.object({
      apiKeyFile: z.string().min(1),
      priority: z.int(),
    }),
  ),
  accountSettings: z
    .record(
      z.string(),
      z.strictObject({
        allowExtraUsage: z.boolean().optional(),
        preferExtraUsage: z.boolean().optional(),
      }),
    )
    .optional(),
});

type Configuration = z.infer<typeof configurationSchema>;
type Specification = z.infer<typeof specificationSchema>;
type Account = z.infer<typeof accountSchema>;

interface Dependencies {
  readKey: (path: string) => Promise<string>;
  defaultConfig: () => Configuration;
  update: (
    change: (config: Configuration | null) => Configuration | undefined,
  ) => Promise<Configuration | undefined>;
  reload: (config: Configuration) => Promise<void>;
}

interface ConfigLibrary {
  createDefaultConfig: () => unknown;
  withConfigLock: <T>(path: string, update: () => Promise<T>) => Promise<T>;
  writeJsonAtomic: (path: string, value: Configuration) => Promise<void>;
}

interface AccountLibrary {
  ensureAccountIds: (accounts: Account[]) => void;
}

interface RuntimeDependencies {
  readText: (path: string) => Promise<string>;
  prepareDirectory: (path: string) => Promise<void>;
  library: ConfigLibrary;
  ensureAccountIds: AccountLibrary["ensureAccountIds"];
  clock: {
    now: () => number;
    pause: () => Promise<void>;
  };
  reload: Dependencies["reload"];
}

const callable = <T extends (...args: never[]) => unknown>() =>
  z.custom<T>((value) => typeof value === "function");

function hasCode(error: unknown, code: string): boolean {
  return z.object({ code: z.literal(code) }).safeParse(error).success;
}

function parse<T>(
  schema: z.ZodType<T>,
  value: unknown,
  target: { source: ValidationSource; path?: string },
): T {
  const result = schema.safeParse(value);

  if (!result.success) {
    throw new InvalidDataError(
      target.source,
      target.path ?? null,
      result.error.issues.map((issue) => issue.path),
    );
  }

  return result.data;
}

async function readJson(
  file: string,
  readText: RuntimeDependencies["readText"],
): Promise<unknown> {
  let text;

  try {
    text = await readText(file);
  } catch (cause) {
    throw new FileReadError(file, { cause });
  }

  try {
    return JSON.parse(text);
  } catch {
    throw new InvalidJsonError(file);
  }
}

function mergeSettings(
  config: Record<string, unknown>,
  settings: Record<string, unknown>,
): void {
  for (const [key, value] of Object.entries(settings)) {
    if (["__proto__", "constructor", "prototype"].includes(key)) {
      throw new UnsupportedFieldError(key);
    }

    const object = objectSchema.safeParse(value);

    if (object.success) {
      const nested = objectSchema.safeParse(config[key]).data ?? {};

      mergeSettings(nested, object.data);
      config[key] = nested;

      continue;
    }

    config[key] = value;
  }
}

function reconcileAccounts(
  config: Configuration,
  keys: Map<string, { apiKey: string; priority: number }>,
): void {
  config.accounts = config.accounts.filter(
    (account) =>
      account.dotfilesManaged !== true ||
      (account.name !== undefined && keys.has(account.name)),
  );

  for (const [name, key] of keys) {
    const matches = config.accounts.filter((account) => account.name === name);

    if (
      matches.length > 1 ||
      matches.some((account) => account.type !== "apikey")
    ) {
      throw new ApiKeyAccountConflictError(name);
    }

    let account = matches[0];

    if (!account) {
      account = { name, type: "apikey" };
      config.accounts.push(account);
    }

    Object.assign(account, key, { dotfilesManaged: true });
    delete account.accessToken;
  }
}

function applyAccountSettings(
  config: Configuration,
  settings: Specification["accountSettings"],
): void {
  for (const [name, policy] of Object.entries(settings ?? {})) {
    const matches = config.accounts.filter((account) => account.name === name);

    if (matches.length > 1) {
      throw new AmbiguousAccountPolicyError(name);
    }

    const account = matches[0];

    if (!account) {
      continue;
    }

    Object.assign(account, policy);
  }
}

async function provision(
  spec: Specification,
  dependencies: Dependencies,
): Promise<void> {
  if ("accounts" in spec.settings) {
    throw new AccountsSettingError();
  }

  const entries = await Promise.all(
    Object.entries(spec.apiKeyAccounts).map(async ([name, account]) => {
      const apiKey = (await dependencies.readKey(account.apiKeyFile)).trim();

      if (!apiKey || /\s/.test(apiKey)) {
        throw new InvalidApiKeyError(account.apiKeyFile);
      }

      return [name, { apiKey, priority: account.priority }] as const;
    }),
  );
  const keys = new Map(entries);

  const updated = await dependencies.update(
    (current): Configuration | undefined => {
      if (
        !current &&
        keys.size === 0 &&
        Object.keys(spec.settings).length === 0
      ) {
        return undefined;
      }

      const config = structuredClone(current ?? dependencies.defaultConfig());

      mergeSettings(config, spec.settings);
      reconcileAccounts(config, keys);
      applyAccountSettings(config, spec.accountSettings);

      return parse(configurationSchema, config, { source: "configuration" });
    },
  );

  if (updated) {
    await dependencies.reload(updated);
  }
}

async function readConfig(
  path: string,
  readText: RuntimeDependencies["readText"],
): Promise<Configuration | null> {
  let config;

  try {
    config = await readJson(path, readText);
  } catch (error) {
    if (error instanceof FileReadError && hasCode(error.cause, "ENOENT")) {
      return null;
    }

    throw error;
  }

  return parse(configurationSchema, config, { source: "configuration", path });
}

/* eslint-disable no-await-in-loop -- Retries must wait for each read or launchd status check before deciding whether to continue. */
async function readKey(
  path: string,
  dependencies: Pick<RuntimeDependencies, "readText" | "clock">,
): Promise<string> {
  const { readText, clock } = dependencies;
  const deadline = clock.now() + 5000;

  for (;;) {
    try {
      return await readText(path);
    } catch (error) {
      if (!hasCode(error, "ENOENT") || clock.now() >= deadline) {
        throw new FileReadError(path, { cause: error });
      }

      await clock.pause();
    }
  }
}

async function waitForSops(
  expectedProgram: string,
  dependencies: {
    status: () => Promise<string>;
    pause: () => Promise<void>;
  },
): Promise<void> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const status = await dependencies.status();
    const program = status.match(/^\tprogram = (.+)$/m)?.[1];
    const argumentsText =
      status.match(/^\targuments = \{\n([\s\S]*?)^\t\}/m)?.[1] ?? "";
    const current =
      program === expectedProgram ||
      argumentsText.split(/\s+/).includes(expectedProgram);
    const stopped = /^\tstate = not running$/m.test(status);
    const started = /^\truns = [1-9][0-9]*$/m.test(status);

    if (current && stopped && started) {
      if (/^\tlast exit code = 0$/m.test(status)) {
        return;
      }

      throw new SopsDecryptionError(expectedProgram);
    }

    await dependencies.pause();
  }

  throw new SopsTimeoutError(expectedProgram);
}

/* eslint-enable no-await-in-loop */

async function reload(
  config: Configuration,
  request: (
    url: string,
    apiKey: string,
  ) => Promise<{ ok: boolean; status: number }>,
): Promise<void> {
  if (config.proxy?.port === undefined || config.proxy.port === 0) {
    return;
  }

  try {
    const response = await request(
      `http://127.0.0.1:${config.proxy.port}/teamclaude/reload`,
      config.proxy.apiKey ?? "",
    );

    if (!response.ok) {
      throw new ReloadHttpError(response.status);
    }
  } catch (error) {
    if (error instanceof Error && hasCode(error.cause, "ECONNREFUSED")) {
      return;
    }

    if (error instanceof ProvisionError) {
      throw error;
    }

    throw new ReloadTransportError({ cause: error });
  }
}

async function run(
  paths: { configFile: string; specFile: string },
  dependencies: RuntimeDependencies,
): Promise<void> {
  const { configFile, specFile } = paths;
  const { library } = dependencies;

  await provision(
    parse(
      specificationSchema,
      await readJson(specFile, dependencies.readText),
      { source: "specification", path: specFile },
    ),
    {
      readKey: (path) => readKey(path, dependencies),
      defaultConfig: () =>
        parse(configurationSchema, library.createDefaultConfig(), {
          source: "default-configuration",
        }),
      update: async (change) => {
        try {
          await dependencies.prepareDirectory(dirname(configFile));

          return await library.withConfigLock(
            configFile,
            async (): Promise<Configuration | undefined> => {
              const current = await readConfig(
                configFile,
                dependencies.readText,
              );
              const updated = change(current);

              if (!updated) {
                return undefined;
              }

              dependencies.ensureAccountIds(updated.accounts);

              if (JSON.stringify(current) !== JSON.stringify(updated)) {
                await library.writeJsonAtomic(configFile, updated);
              }

              return updated;
            },
          );
        } catch (cause) {
          if (cause instanceof ProvisionError) {
            throw cause;
          }

          throw new ConfigurationWriteError(configFile, { cause });
        }
      },
      reload: dependencies.reload,
    },
  );
}

export interface SystemDependencies {
  readText: RuntimeDependencies["readText"];
  prepareDirectory: RuntimeDependencies["prepareDirectory"];
  importModule: (url: string) => Promise<unknown>;
  sopsStatus: () => Promise<string>;
  clock: RuntimeDependencies["clock"];
  requestReload: Parameters<typeof reload>[1];
}

export async function main(
  args: string[],
  system: SystemDependencies,
): Promise<void> {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: { "sops-program": { type: "string" } },
  });
  const [configModule, specFile] = positionals;

  if (
    configModule === undefined ||
    configModule === "" ||
    specFile === undefined ||
    specFile === ""
  ) {
    throw new InvalidArgumentsError();
  }

  if (values["sops-program"] !== undefined && values["sops-program"] !== "") {
    await waitForSops(values["sops-program"], {
      status: system.sopsStatus,
      pause: system.clock.pause,
    });
  }

  const library = parse(
    z.object({
      createDefaultConfig: callable<ConfigLibrary["createDefaultConfig"]>(),
      withConfigLock: callable<ConfigLibrary["withConfigLock"]>(),
      writeJsonAtomic: callable<ConfigLibrary["writeJsonAtomic"]>(),
      getConfigPath: callable<() => string>(),
    }),
    await system.importModule(pathToFileURL(configModule).href),
    { source: "config-library" },
  );
  const accounts = parse(
    z.object({
      ensureAccountIds: callable<AccountLibrary["ensureAccountIds"]>(),
    }),
    await system.importModule(
      new URL("./account-id.js", pathToFileURL(configModule)).href,
    ),
    { source: "account-library" },
  );

  await run(
    { configFile: library.getConfigPath(), specFile },
    {
      readText: system.readText,
      prepareDirectory: system.prepareDirectory,
      library,
      ensureAccountIds: accounts.ensureAccountIds,
      clock: system.clock,
      reload: (config) => reload(config, system.requestReload),
    },
  );
}
