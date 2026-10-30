import {
  ConfigurationReadError,
  LoopbackDisabledError,
  PortConflictError,
  type ValidationSource,
} from "./errors.ts";
import { decodeJson, validate } from "./validation.ts";
import { readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { z } from "zod";

const port = z.number().int().min(1).max(65535);
const absolutePath = z.string().refine(isAbsolute, "Expected an absolute path");

export const configSchema = z.strictObject({
  port: port.default(3457),
  teamclaudeConfigFile: absolutePath,
  stateDirectory: absolutePath,
  account: z.string().min(1).nullable().default(null),
  maxBodyBytes: z
    .number()
    .int()
    .positive()
    .default(32 * 1024 * 1024),
  timeoutMs: z.number().int().min(1000).default(300000),
});

export type Config = z.infer<typeof configSchema>;

async function readConfiguration(
  path: string,
  source: ValidationSource,
): Promise<unknown> {
  let content: string;

  try {
    content = await readFile(path, "utf8");
  } catch (cause) {
    throw new ConfigurationReadError(path, { cause });
  }

  return decodeJson(content, source);
}

export async function loadConfig(path: string): Promise<Config> {
  const decoded = await readConfiguration(path, "frontend");

  return validate(configSchema, decoded, "frontend");
}

export async function upstreamPort(config: Config): Promise<number> {
  const decoded = await readConfiguration(
    config.teamclaudeConfigFile,
    "teamclaude",
  );
  const schema = z.object({
    proxy: z
      .object({
        port: port.default(3456),
        trustLoopback: z.boolean().default(true),
      })
      .default({ port: 3456, trustLoopback: true }),
  });
  const runtime = validate(schema, decoded, "teamclaude");

  if (!runtime.proxy.trustLoopback) {
    throw new LoopbackDisabledError();
  }

  if (runtime.proxy.port === config.port) {
    throw new PortConflictError(config.port);
  }

  return runtime.proxy.port;
}
