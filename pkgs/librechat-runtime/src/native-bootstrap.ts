import { StatusCodes } from "http-status-codes";
import { createRequire } from "node:module";
import { EventEmitter, once } from "node:events";
import { mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import {
  BootstrapAgentAlreadyExistsError,
  configuredPersonalAgents,
  personalAgentData,
  provisionAgents,
  type BootstrapOwner,
  type StoredAgent,
} from "./bootstrap.ts";
import { hasEmbeddingProvider, writePrivateJson } from "./config.ts";
import type { HostManifest } from "./manifest.ts";

type NativeFunction = (...args: unknown[]) => unknown;

export class BootstrapExportError extends Error {
  readonly exportName: string;

  constructor(exportName: string) {
    super(
      `The installed LibreChat package does not provide the bootstrap export: ${exportName}`,
    );

    this.name = "BootstrapExportError";

    this.exportName = exportName;
  }
}

export class BootstrapRegistrationError extends Error {
  constructor() {
    super(
      "LibreChat refused account creation; check the email and password requirements",
    );

    this.name = "BootstrapRegistrationError";
  }
}

export class BootstrapAccountMismatchError extends Error {
  constructor() {
    super("This deployment is already bound to another personal account");

    this.name = "BootstrapAccountMismatchError";
  }
}

function nativeFunction(value: unknown): value is NativeFunction {
  return typeof value === "function";
}

function member(value: unknown, key: string): unknown {
  if (
    (typeof value !== "object" || value === null) &&
    typeof value !== "function"
  ) {
    throw new BootstrapExportError(key);
  }

  const result: unknown = Reflect.get(value, key);

  return result;
}

function invoke(value: unknown, key: string, ...args: unknown[]): unknown {
  const method = member(value, key);

  if (!nativeFunction(method)) {
    throw new BootstrapExportError(key);
  }

  return method.apply(value, args);
}

const objectId = z.coerce.string().regex(/^[a-f0-9]{24}$/u);

const ownerSchema = z
  .object({ _id: objectId, email: z.email(), tenantId: z.string().optional() })
  .transform(({ _id: userId, ...owner }) => ({ ...owner, userId }));

const agentSchema = z
  .object({
    id: z.string(),
    _id: objectId,
    author: objectId,
    provider: z.string(),
    tenantId: z.string().optional(),
  })
  .transform(({ _id: databaseId, ...agent }) => ({ ...agent, databaseId }));

function storedAgent(raw: unknown): StoredAgent {
  const agent = agentSchema.parse(raw);

  return {
    id: agent.id,
    databaseId: agent.databaseId,
    author: agent.author,
    provider: agent.provider,
    tenantId: agent.tenantId,
  };
}

async function readPreviousAccount(file: string): Promise<unknown> {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error: unknown) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return null;
    }

    throw error;
  }
}

export async function bootstrapAccount(
  manifest: HostManifest,
  input: { email: string; passwordFile: string; name: string },
): Promise<void> {
  const { name: displayName } = z
    .object({ name: z.string().trim().min(3).max(80) })
    .parse(input);

  const email = z.email().parse(input.email.toLowerCase());

  const accountFile = join(manifest.stateDirectory, "account.json");

  const previousRaw = await readPreviousAccount(accountFile);

  if (
    previousRaw !== null &&
    z.object({ email: z.string() }).parse(previousRaw).email !== email
  ) {
    throw new BootstrapAccountMismatchError();
  }

  const connectionRaw: unknown = JSON.parse(
    await readFile(join(manifest.stateDirectory, "connection.json"), "utf8"),
  );

  const connection = z.object({ mongoUri: z.string() }).parse(connectionRaw);

  await mkdir(join(manifest.stateDirectory, "logs"), {
    recursive: true,
    mode: 0o700,
  });

  const bootstrapConfiguration = join(
    manifest.stateDirectory,
    "bootstrap-config.json",
  );

  await writePrivateJson(bootstrapConfiguration, {
    version: "1.3.18",
    endpoints: { agents: {} },
  });

  process.env.CONFIG_PATH = bootstrapConfiguration;

  process.env.MONGO_URI = connection.mongoUri;

  process.env.LIBRECHAT_LOG_DIR = join(manifest.stateDirectory, "logs");

  const require = createRequire(
    `${manifest.programs.librechatRoot}/package.json`,
  );

  const aliases: unknown = require("module-alias");

  if (!nativeFunction(aliases)) {
    throw new BootstrapExportError("module-alias");
  }

  aliases({ base: join(manifest.programs.librechatRoot, "api") });

  require(join(manifest.programs.librechatRoot, "api", "db", "models"));

  const database: unknown = require(
    join(manifest.programs.librechatRoot, "api", "db", "connect"),
  );

  const mongoose: unknown = require("mongoose");

  const dataSchemas: unknown = require("@librechat/data-schemas");

  const logger = member(dataSchemas, "logger");

  if (!(logger instanceof EventEmitter)) {
    throw new BootstrapExportError("logger");
  }

  try {
    invoke(logger, "info", "LibreChat bootstrap provisioning started.");

    await Promise.resolve(invoke(database, "connectDb"));

    const modelNames = z
      .array(z.string())
      .parse(invoke(mongoose, "modelNames"));

    await Promise.all(
      modelNames.map(async (name) => {
        const model = invoke(mongoose, "model", name);

        await Promise.resolve(invoke(model, "init"));
      }),
    );

    const methods: unknown = require(
      join(manifest.programs.librechatRoot, "api", "models"),
    );

    await Promise.resolve(invoke(methods, "seedDatabase"));

    const lookup = async (): Promise<unknown> =>
      await Promise.resolve(
        invoke(
          dataSchemas,
          "runAsSystem",
          async () =>
            await Promise.resolve(invoke(methods, "findUser", { email })),
        ),
      );

    let rawOwner = await lookup();

    if (rawOwner === null) {
      const password = z
        .string()
        .min(1)
        .max(512)
        .parse(
          (await readFile(input.passwordFile, "utf8")).replace(/\r?\n$/u, ""),
        );

      const auth: unknown = require(
        join(
          manifest.programs.librechatRoot,
          "api",
          "server",
          "services",
          "AuthService",
        ),
      );

      const registration = {
        email,
        name: displayName,
        password,
        confirm_password: password,
      };

      const validators: unknown = require(
        join(
          manifest.programs.librechatRoot,
          "api",
          "strategies",
          "validators",
        ),
      );

      const validation = invoke(
        member(validators, "registerSchema"),
        "safeParse",
        registration,
      );

      if (!z.object({ success: z.boolean() }).parse(validation).success) {
        throw new BootstrapRegistrationError();
      }

      const result = await Promise.resolve(
        invoke(auth, "registerUser", registration, { emailVerified: true }),
      );

      if (
        z.object({ status: z.enum(StatusCodes) }).parse(result).status !==
        StatusCodes.OK
      ) {
        throw new BootstrapRegistrationError();
      }

      rawOwner = await lookup();
    }

    const parsedOwner = ownerSchema.parse(rawOwner);

    if (
      previousRaw !== null &&
      z.object({ userId: objectId }).parse(previousRaw).userId !==
        parsedOwner.userId
    ) {
      throw new BootstrapAccountMismatchError();
    }

    const owner: BootstrapOwner = {
      userId: parsedOwner.userId,
      email: parsedOwner.email,
      tenantId: parsedOwner.tenantId,
    };

    const permissionService: unknown = require(
      join(
        manifest.programs.librechatRoot,
        "api",
        "server",
        "services",
        "PermissionService",
      ),
    );

    const tenantStorage = member(dataSchemas, "tenantStorage");

    await Promise.resolve(
      invoke(
        tenantStorage,
        "run",
        { tenantId: owner.tenantId, userId: owner.userId },
        async () => {
          z.object({ name: z.literal(displayName) }).parse(
            await Promise.resolve(
              invoke(
                methods,
                "updateUser",
                owner.userId,
                { name: displayName },
                {},
                { preserveExpiresAt: true },
              ),
            ),
          );

          await provisionAgents(
            owner,
            configuredPersonalAgents(manifest.providers, manifest.models),
            {
              load: async (id) => {
                const found = await Promise.resolve(
                  invoke(methods, "getAgent", { id }),
                );

                return found === null ? null : storedAgent(found);
              },
              create: async (agent) => {
                try {
                  return storedAgent(
                    await Promise.resolve(
                      invoke(
                        methods,
                        "createAgent",
                        personalAgentData(agent, owner, {
                          instructions: manifest.instructions,
                          servers: [
                            ...manifest.localMcpServers,
                            ...Object.keys(manifest.mcpServers),
                          ],
                          fileSearch: hasEmbeddingProvider(manifest.providers),
                        }),
                      ),
                    ),
                  );
                } catch (error) {
                  if (
                    error instanceof Error &&
                    "code" in error &&
                    error.code === 11000
                  ) {
                    throw new BootstrapAgentAlreadyExistsError();
                  }

                  throw error;
                }
              },
              setProvider: async (agent, provider) => {
                await Promise.resolve(
                  invoke(
                    methods,
                    "updateAgent",
                    {
                      id: agent.id,
                      author: owner.userId,
                      provider: agent.provider,
                    },
                    { provider },
                    { updatingUserId: owner.userId },
                  ),
                );
              },
              grantOwner: async (agent) => {
                await Promise.all(
                  [
                    ["agent", "agent_owner"],
                    ["remoteAgent", "remoteAgent_owner"],
                  ].map(
                    async ([resourceType, accessRoleId]) =>
                      await Promise.resolve(
                        invoke(permissionService, "grantPermission", {
                          principalType: "user",
                          principalId: owner.userId,
                          resourceType,
                          resourceId: agent.databaseId,
                          accessRoleId,
                          grantedBy: owner.userId,
                        }),
                      ),
                  ),
                );
              },
            },
          );
        },
      ),
    );

    await writePrivateJson(accountFile, owner);
  } finally {
    try {
      await Promise.resolve(invoke(mongoose, "disconnect"));
    } finally {
      const finished = once(logger, "finish");

      invoke(logger, "end");

      await finished;
    }
  }
}
