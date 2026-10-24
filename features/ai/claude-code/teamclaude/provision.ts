import { mkdir, readFile } from "node:fs/promises";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout } from "node:timers/promises";
import { execFile } from "node:child_process";
import { userInfo } from "node:os";
import { parseArgs, promisify } from "node:util";
import { z } from "zod";

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
  settings: z
    .record(z.string(), z.json())
    .refine((settings) => !("accounts" in settings), {
      message: "Declare accounts through apiKeyAccounts, not settings",
    }),
  apiKeyAccounts: z.record(
    z.string(),
    z.object({
      apiKeyFile: z.string().min(1),
      priority: z.int(),
    }),
  ),
});
export type Configuration = z.infer<typeof configurationSchema>;
export type Specification = z.infer<typeof specificationSchema>;
type Account = z.infer<typeof accountSchema>;

export interface Dependencies {
  readKey(path: string): Promise<string>;
  defaultConfig(): Configuration;
  update(
    change: (config: Configuration | null) => Configuration | undefined,
  ): Promise<Configuration | undefined>;
  reload(config: Configuration): Promise<void>;
}
interface ConfigLibrary {
  createDefaultConfig(): Configuration;
  getConfigPath(): string;
  withConfigLock<T>(path: string, update: () => Promise<T>): Promise<T>;
  writeJsonAtomic(path: string, value: Configuration): Promise<void>;
}
interface AccountLibrary {
  ensureAccountIds(accounts: Account[]): void;
}

function hasCode(error: unknown, code: string): boolean {
  return z.object({ code: z.literal(code) }).safeParse(error).success;
}

function parse<T>(
  schema: z.ZodType<T>,
  value: unknown,
  description: string,
): T {
  const result = schema.safeParse(value);
  if (!result.success) {
    throw new Error(`Invalid ${description}`);
  }
  return result.data;
}

async function readJson(file: string): Promise<unknown> {
  const text = await readFile(file, "utf8");
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`Invalid JSON in ${file}`);
  }
}

function mergeSettings(
  config: Record<string, unknown>,
  settings: Record<string, unknown>,
): void {
  for (const [key, value] of Object.entries(settings)) {
    if (["__proto__", "constructor", "prototype"].includes(key)) {
      throw new Error(`Unsupported configuration field: ${key}`);
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
      !account.dotfilesManaged ||
      (account.name !== undefined && keys.has(account.name)),
  );
  for (const [name, key] of keys) {
    const matches = config.accounts.filter((account) => account.name === name);
    if (
      matches.length > 1 ||
      matches.some((account) => account.type !== "apikey")
    ) {
      throw new Error(
        `API-key account ${name} conflicts with existing accounts`,
      );
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

export async function provision(
  spec: Specification,
  dependencies: Dependencies,
): Promise<void> {
  if ("accounts" in spec.settings) {
    throw new Error("Declare accounts through apiKeyAccounts, not settings");
  }
  const keys = new Map<string, { apiKey: string; priority: number }>();
  for (const [name, account] of Object.entries(spec.apiKeyAccounts)) {
    const apiKey = (await dependencies.readKey(account.apiKeyFile)).trim();
    if (!apiKey || /\s/.test(apiKey)) {
      throw new Error(`Expected a single API key in ${account.apiKeyFile}`);
    }
    keys.set(name, { apiKey, priority: account.priority });
  }
  const updated = await dependencies.update((current) => {
    if (!current && !keys.size && !Object.keys(spec.settings).length) {
      return;
    }
    const config = structuredClone(current ?? dependencies.defaultConfig());
    mergeSettings(config, spec.settings);
    reconcileAccounts(config, keys);
    return parse(configurationSchema, config, "TeamClaude configuration");
  });
  if (updated) {
    await dependencies.reload(updated);
  }
}

async function readConfig(path: string): Promise<Configuration | null> {
  let config;
  try {
    config = await readJson(path);
  } catch (error) {
    if (hasCode(error, "ENOENT")) {
      return null;
    }
    throw error;
  }
  return parse(
    configurationSchema,
    config,
    `TeamClaude configuration in ${path}`,
  );
}

async function readKey(path: string): Promise<string> {
  const deadline = Date.now() + 5000;
  for (;;) {
    try {
      return await readFile(path, "utf8");
    } catch (error) {
      if (!hasCode(error, "ENOENT") || Date.now() >= deadline) {
        throw error;
      }
      await setTimeout(100);
    }
  }
}

export async function waitForSops(dependencies: {
  status(): Promise<string>;
  pause(): Promise<void>;
}): Promise<void> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const status = await dependencies.status();
    const stopped = /^\tstate = not running$/m.test(status);
    const started = /^\truns = [1-9][0-9]*$/m.test(status);
    if (stopped && started) {
      if (/^\tlast exit code = 0$/m.test(status)) {
        return;
      }
      throw new Error("sops-nix failed to decrypt secrets");
    }
    await dependencies.pause();
  }
  throw new Error("Timed out waiting for sops-nix to decrypt secrets");
}

async function reload(config: Configuration): Promise<void> {
  if (!config.proxy?.port) {
    return;
  }
  try {
    const response = await fetch(
      `http://127.0.0.1:${config.proxy.port}/teamclaude/reload`,
      {
        method: "POST",
        headers: { "x-api-key": config.proxy.apiKey ?? "" },
        signal: AbortSignal.timeout(5000),
      },
    );
    if (!response.ok) {
      throw new Error(
        `TeamClaude configuration reload returned ${response.status}`,
      );
    }
  } catch (error) {
    if (error instanceof Error && hasCode(error.cause, "ECONNREFUSED")) {
      return;
    }
    throw error;
  }
}

export async function run(
  configModule: string,
  specFile: string,
  notify: Dependencies["reload"] = reload,
): Promise<void> {
  const library: ConfigLibrary = await import(pathToFileURL(configModule).href);
  const accountLibrary: AccountLibrary = await import(
    new URL("./account-id.js", pathToFileURL(configModule)).href
  );
  const path = library.getConfigPath();
  await provision(
    parse(
      specificationSchema,
      await readJson(specFile),
      `provisioning specification in ${specFile}`,
    ),
    {
      readKey,
      defaultConfig: () =>
        parse(
          configurationSchema,
          library.createDefaultConfig(),
          "default TeamClaude configuration",
        ),
      update: async (change) => {
        await mkdir(dirname(path), { recursive: true, mode: 0o700 });
        return library.withConfigLock(path, async () => {
          const current = await readConfig(path);
          const updated = change(current);
          if (!updated) {
            return;
          }
          accountLibrary.ensureAccountIds(updated.accounts);
          if (JSON.stringify(current) !== JSON.stringify(updated)) {
            await library.writeJsonAtomic(path, updated);
          }
          return updated;
        });
      },
      reload: notify,
    },
  );
}

if (import.meta.main) {
  try {
    const { values, positionals } = parseArgs({
      allowPositionals: true,
      options: { "wait-for-sops": { type: "boolean" } },
    });
    const [configModule, specFile] = positionals;
    if (!configModule || !specFile) {
      throw new Error(
        "Usage: provision.ts <TeamClaude config module> <specification>",
      );
    }
    if (values["wait-for-sops"]) {
      const launchctl = promisify(execFile);
      await waitForSops({
        status: async () => {
          try {
            const result = await launchctl("/bin/launchctl", [
              "print",
              `gui/${userInfo().uid}/org.nix-community.home.sops-nix`,
            ]);
            return result.stdout;
          } catch {
            return "";
          }
        },
        pause: () => setTimeout(100),
      });
    }
    await run(configModule, specFile);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error(`teamclaude: provisioning failed: ${message}`);
    process.exitCode = 1;
  }
}
