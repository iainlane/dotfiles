import {
  CredentialReadError,
  CredentialFormatError,
  OllamaEndpointError,
  type CredentialLabel,
} from "./errors.ts";
import { randomBytes } from "node:crypto";
import { link, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { dirname } from "node:path";

interface LocalMcpServer {
  type: "streamable-http";
  url: string;
  requiresOAuth: false;
  headers: { Authorization: string };
  requestHeaders: {
    "X-LibreChat-User-ID": string;
    "X-LibreChat-Conversation-ID": string;
  };
  serverInstructions: boolean;
}

export function configureLocalMcp(servers: readonly string[]): {
  mcpServers: Record<string, LocalMcpServer>;
  mcpSettings: { allowedAddresses: string[] };
} {
  const mcpServers = Object.fromEntries(
    servers.map((name): [string, LocalMcpServer] => [
      name,
      {
        type: "streamable-http",
        url: `http://127.0.0.1:3193/mcp/${name}`,
        requiresOAuth: false,
        headers: { Authorization: "Bearer ${LIBRECHAT_MCP_TOKEN}" },
        requestHeaders: {
          "X-LibreChat-User-ID": "{{LIBRECHAT_USER_ID}}",
          "X-LibreChat-Conversation-ID": "{{LIBRECHAT_BODY_CONVERSATIONID}}",
        },
        serverInstructions: true,
      },
    ]),
  );

  return {
    mcpServers,
    mcpSettings: {
      allowedAddresses: servers.length === 0 ? [] : ["127.0.0.1:3193"],
    },
  };
}

export interface ProviderOptions {
  ollamaUrl?: string | null;
  openaiKeyFile?: string | null;
  anthropicKeyFile?: string | null;
  openrouterKeyFile?: string | null;
}

export function hasEmbeddingProvider(options: ProviderOptions): boolean {
  return (
    typeof options.ollamaUrl === "string" ||
    typeof options.openaiKeyFile === "string"
  );
}

interface CustomEndpoint {
  name: string;
  apiKey: string;
  baseURL: string;
  models: { default: string[]; fetch: boolean };
  modelDisplayLabel: string;
}

export interface ProviderConfiguration {
  endpoints: { custom: CustomEndpoint[] };
  environment: Record<string, string>;
}

export type CredentialReader = (
  file: string,
  label: CredentialLabel,
) => Promise<string>;

export async function readCredential(
  file: string,
  label: CredentialLabel,
): Promise<string> {
  let value: string;

  try {
    value = (await readFile(file, "utf8")).trim();
  } catch (cause) {
    throw new CredentialReadError({ file, label }, cause);
  }

  if (!value || /[\r\n\0]/u.test(value)) {
    throw new CredentialFormatError({ file, label });
  }

  return value;
}

export async function configureProviders(
  options: ProviderOptions,
  readKey: CredentialReader = readCredential,
): Promise<ProviderConfiguration> {
  const environment: Record<string, string> = {};

  const enabled = ["agents"];

  const custom: CustomEndpoint[] = [];

  const providers = [
    ["OpenAI", "OPENAI_API_KEY", options.openaiKeyFile, "openAI"],
    ["Anthropic", "ANTHROPIC_API_KEY", options.anthropicKeyFile, "anthropic"],
    ["OpenRouter", "OPENROUTER_API_KEY", options.openrouterKeyFile, "custom"],
  ] as const;

  const credentials = await Promise.all(
    providers.map(async ([name, variable, file, endpoint]) => {
      if (file === null || file === undefined) {
        return null;
      }

      return { variable, endpoint, key: await readKey(file, name) };
    }),
  );

  for (const credential of credentials) {
    if (credential === null) {
      continue;
    }

    const { variable, endpoint, key } = credential;
    environment[variable] = key;

    enabled.push(endpoint);
  }

  if (options.ollamaUrl !== null && options.ollamaUrl !== undefined) {
    const url = URL.parse(options.ollamaUrl);

    if (
      url === null ||
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password ||
      url.search ||
      url.hash
    ) {
      throw new OllamaEndpointError();
    }

    custom.push({
      name: "Ollama",
      apiKey: "ollama",
      baseURL: `${url.href.replace(/\/+$/u, "")}/v1`,
      models: { default: [], fetch: true },
      modelDisplayLabel: "Ollama",
    });
  }

  if (
    options.openrouterKeyFile !== null &&
    options.openrouterKeyFile !== undefined
  ) {
    custom.push({
      name: "OpenRouter",
      apiKey: "${OPENROUTER_API_KEY}",
      baseURL: "https://openrouter.ai/api/v1",
      models: { default: [], fetch: true },
      modelDisplayLabel: "OpenRouter",
    });
  }

  if (custom.length > 0) {
    enabled.push("custom");
  }

  environment.ENDPOINTS = [...new Set(enabled)].join(",");

  return { endpoints: { custom }, environment };
}

async function syncParent(file: string): Promise<void> {
  const directory = await open(dirname(file), "r");

  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}

export async function writePrivateFile(
  file: string,
  contents: string | Uint8Array,
): Promise<void> {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });

  const temporary = `${file}.${randomBytes(12).toString("hex")}.tmp`;

  try {
    const handle = await open(temporary, "wx", 0o600);

    try {
      await handle.writeFile(contents);

      await handle.sync();
    } finally {
      await handle.close();
    }

    await rename(temporary, file);

    await syncParent(file);
  } finally {
    await rm(temporary, { force: true });
  }
}

export async function writePrivateJson(
  file: string,
  value: unknown,
): Promise<void> {
  await writePrivateFile(file, `${JSON.stringify(value, null, 2)}\n`);
}

export async function persistentSecret(file: string): Promise<string> {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });

  const temporary = `${file}.${randomBytes(12).toString("hex")}.tmp`;

  try {
    await writePrivateFile(temporary, randomBytes(32).toString("hex"));

    try {
      await link(temporary, file);
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !("code" in error) ||
        error.code !== "EEXIST"
      ) {
        throw error;
      }
    }

    await syncParent(file);

    return await readCredential(file, "Generated service");
  } finally {
    await rm(temporary, { force: true });
  }
}
