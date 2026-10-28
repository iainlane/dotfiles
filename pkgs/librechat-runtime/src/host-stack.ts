import {
  createPublicKey,
  createPrivateKey,
  generateKeyPairSync,
  randomUUID,
} from "node:crypto";
import { mkdir, readFile, stat } from "node:fs/promises";
import { networkInterfaces } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import type { Server } from "node:http";
import { MongoClient } from "mongodb";
import { z } from "zod";
import { configuredPersonalAgents } from "./bootstrap.ts";
import { ArchiveBroker } from "./archive.ts";
import { ConversationRuntimeSupervisor } from "./bridge.ts";
import {
  BridgeWorker,
  executionManifestBodySha256,
  verifyExecutionManifestWithPublicKey,
} from "./bridge-worker.mjs";
import {
  configureLocalMcp,
  configureProviders,
  hasEmbeddingProvider,
  persistentSecret,
  readCredential,
  writePrivateFile,
  writePrivateJson,
} from "./config.ts";
import { ControllerRouter } from "./controller.ts";
import { SessionBusyError } from "./errors.ts";
import { httpService } from "./http-server.ts";
import { fetchSocket } from "./http-socket.ts";
import { CODE_ENVIRONMENT_ID, CODE_TENANT_ID } from "./identity.ts";
import { credentialService, ironConfiguration } from "./iron-service.ts";
import type { HostManifest } from "./manifest.ts";
import { McpRouter } from "./mcp-router.ts";
import {
  type ProcessRunner,
  type Command,
  type ManagedProcess,
} from "./processes.ts";
import { JsonSessionStore } from "./session-store.ts";
import { SessionManager } from "./sessions.ts";
import { QemuBackend } from "./vm-backend.ts";
import { FileVmStorage, ensurePrivateSocketDirectory } from "./vm-files.ts";
import { stopExistingVm } from "./vm-monitor.ts";
import { ReadinessWaiter, httpReady } from "./startup.ts";

const accountSchema = z.object({
  userId: z.string().regex(/^[a-f0-9]{24}$/u),
  email: z.email(),
});

const keySchema = z.object({ privateKey: z.string(), publicKey: z.string() });

const secretSchema = z.object({
  mongodb: z.string(),
  postgres: z.string(),
  redis: z.string(),
  meili: z.string(),
  objects: z.string(),
  bridge: z.string(),
  internal: z.string(),
  egress: z.string(),
  controller: z.string(),
  archive: z.string(),
  jwt: z.string(),
  refresh: z.string(),
  encryption: z.string(),
  iv: z.string(),
});

export class MongoReadinessError extends Error {
  constructor() {
    super("MongoDB did not become ready before its startup deadline");

    this.name = "MongoReadinessError";
  }
}

export class PostgresReadinessError extends Error {
  constructor() {
    super("PostgreSQL did not become ready before its startup deadline");

    this.name = "PostgresReadinessError";
  }
}

export class CodeApiReadinessError extends Error {
  constructor() {
    super("CodeAPI did not become ready before its startup deadline");

    this.name = "CodeApiReadinessError";
  }
}

export class RagReadinessError extends Error {
  constructor() {
    super("The retrieval API did not become ready before its startup deadline");

    this.name = "RagReadinessError";
  }
}

export class AccountBootstrapReadinessError extends Error {
  constructor() {
    super("The personal account has not been bootstrapped");

    this.name = "AccountBootstrapReadinessError";
  }
}

async function exists(file: string): Promise<boolean> {
  try {
    await stat(file);

    return true;
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }

    throw error;
  }
}

async function keyPair(file: string): Promise<z.infer<typeof keySchema>> {
  if (await exists(file)) {
    const raw: unknown = JSON.parse(await readFile(file, "utf8"));

    return keySchema.parse(raw);
  }

  const generated = generateKeyPairSync("ed25519");

  const keys = {
    privateKey: generated.privateKey
      .export({ type: "pkcs8", format: "der" })
      .toString("base64"),
    publicKey: generated.publicKey
      .export({ type: "spki", format: "der" })
      .toString("base64"),
  };

  await writePrivateJson(file, keys);

  return keys;
}

function report(error: unknown): void {
  process.stderr.write(
    `${error instanceof Error ? error.name : "ServiceFailure"}\n`,
  );
}

export class NativeHostStack {
  private readonly manifest: HostManifest;
  private readonly processes: ProcessRunner;
  private readonly children: ManagedProcess[] = [];
  private readonly failure = Promise.withResolvers<unknown>();
  private readonly monitors: Promise<void>[] = [];
  private sweepTask: Promise<void> | undefined;
  private readonly signal: AbortSignal;
  private readonly readiness: ReadinessWaiter;
  private readonly abort = new AbortController();
  private sessions: SessionManager | undefined;
  private servers: Server[] = [];
  private closeCredentials: (() => void) | undefined;

  constructor(
    manifest: HostManifest,
    signal: AbortSignal,
    processes: ProcessRunner,
  ) {
    this.manifest = manifest;

    this.signal = AbortSignal.any([signal, this.abort.signal]);

    this.readiness = new ReadinessWaiter({
      signal: this.signal,
      pause: async () => {
        await delay(1000, undefined, { signal: this.signal });
      },
    });

    this.processes = processes;
  }

  private async monitor(operation: Promise<void>): Promise<void> {
    try {
      await operation;
    } catch (error) {
      this.failure.resolve(error);
    }
  }

  private async waitForFailure(): Promise<never> {
    const error = await this.failure.promise;

    if (error instanceof Error) {
      throw error;
    }

    throw new Error("A native LibreChat service failed", { cause: error });
  }

  private async sweep(sessions: SessionManager): Promise<void> {
    try {
      await sessions.sweep();
    } catch (error) {
      report(error);
    } finally {
      this.sweepTask = undefined;
    }
  }

  private async start(command: Command): Promise<void> {
    this.signal.throwIfAborted();

    const child = await this.processes.start(command);

    if (this.signal.aborted) {
      await child.stop();

      this.signal.throwIfAborted();
    }

    this.children.push(child);

    this.monitors.push(this.monitor(child.exited));
  }

  private async mongo(uri: string, password: string): Promise<boolean> {
    const client = new MongoClient(uri, { serverSelectionTimeoutMS: 500 });

    try {
      await client.connect();

      await client.db("admin").command({ ping: 1 });

      return true;
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !("code" in error) ||
        error.code !== 18
      ) {
        return false;
      }

      const bootstrap = new MongoClient(
        `mongodb://127.0.0.1:${this.manifest.ports.mongodb}`,
        {
          serverSelectionTimeoutMS: 500,
        },
      );

      try {
        await bootstrap
          .db("admin")
          .command({ createUser: "librechat", pwd: password, roles: ["root"] });
      } catch {
        return false;
      } finally {
        await bootstrap.close();
      }

      return true;
    } finally {
      await client.close();
    }
  }

  private async run(): Promise<void> {
    const { manifest } = this;

    const { ports } = manifest;

    const state = manifest.stateDirectory;

    const programs = manifest.programs;

    const socketDirectory =
      manifest.socketDirectory ?? `/tmp/librechat-${process.getuid?.() ?? 0}`;

    await Promise.all(
      [
        state,
        socketDirectory,
        ...[
          "secrets",
          "mongodb",
          "postgres",
          "redis",
          "objects",
          "iron",
          "app",
          "uploads",
          "rag",
          "plugins",
          "plugin-data",
          "sessions",
        ].map((name) => join(state, name)),
      ].map(async (directory) =>
        mkdir(directory, { recursive: true, mode: 0o700 }),
      ),
    );

    await ensurePrivateSocketDirectory(
      socketDirectory,
      process.getuid?.() ?? 0,
    );

    const secretEntries = await Promise.all(
      Object.keys(secretSchema.shape).map(async (name) => [
        name,
        await persistentSecret(join(state, "secrets", name)),
      ]),
    );

    const secrets = secretSchema.parse(Object.fromEntries(secretEntries));

    const authKey = await keyPair(join(state, "secrets", "code-auth.json"));

    const executionKey = await keyPair(
      join(state, "secrets", "execution.json"),
    );

    const mongoUri = `mongodb://librechat:${secrets.mongodb}@127.0.0.1:${ports.mongodb}/LibreChat?authSource=admin`;

    await writePrivateJson(join(state, "connection.json"), { mongoUri });

    await this.start({
      executable: programs.mongodb,
      args: [
        "--dbpath",
        join(state, "mongodb"),
        "--bind_ip",
        "127.0.0.1",
        "--port",
        String(ports.mongodb),
        "--auth",
      ],
    });

    await this.readiness.wait(
      () => this.mongo(mongoUri, secrets.mongodb),
      MongoReadinessError,
    );

    const postgresDirectory = join(state, "postgres");

    if (!(await exists(join(postgresDirectory, "PG_VERSION")))) {
      await this.processes.run({
        executable: programs.initdb,
        args: [
          "-D",
          postgresDirectory,
          "--username=librechat",
          `--pwfile=${join(state, "secrets", "postgres")}`,
          "--auth-local=trust",
          "--auth-host=scram-sha-256",
          "--no-locale",
          "--encoding=UTF8",
        ],
      });
    }

    await this.start({
      executable: programs.postgres,
      args: [
        "-D",
        postgresDirectory,
        "-h",
        "127.0.0.1",
        "-p",
        String(ports.postgres),
        "-k",
        socketDirectory,
      ],
    });

    const sql = async (database: string, statement: string): Promise<string> =>
      await this.processes.run({
        executable: programs.psql,
        args: [
          "-h",
          socketDirectory,
          "-p",
          String(ports.postgres),
          "-U",
          "librechat",
          "-d",
          database,
          "-X",
          "-tAc",
          statement,
          "--set=ON_ERROR_STOP=1",
        ],
      });

    await this.readiness.wait(async () => {
      try {
        await sql("postgres", "SELECT 1");

        return true;
      } catch {
        return false;
      }
    }, PostgresReadinessError);

    if (
      (
        await sql(
          "postgres",
          "SELECT 1 FROM pg_database WHERE datname = 'librechat'",
        )
      ).trim() !== "1"
    ) {
      await sql("postgres", "CREATE DATABASE librechat");
    }

    await sql("librechat", "CREATE EXTENSION IF NOT EXISTS vector");

    const redisConfiguration = join(state, "redis.conf");

    await writePrivateFile(
      redisConfiguration,
      `bind 127.0.0.1\nport ${ports.redis}\nprotected-mode yes\nrequirepass ${secrets.redis}\nappendonly yes\nappendfsync everysec\ndir ${JSON.stringify(join(state, "redis"))}\n`,
    );

    await this.start({
      executable: programs.redis,
      args: [redisConfiguration],
    });

    await this.start({
      executable: programs.meilisearch,
      args: [],
      environment: {
        MEILI_HTTP_ADDR: `127.0.0.1:${ports.meilisearch}`,
        MEILI_DB_PATH: join(state, "meili"),
        MEILI_DUMP_DIR: join(state, "meili-dumps"),
        MEILI_SNAPSHOT_DIR: join(state, "meili-snapshots"),
        MEILI_MASTER_KEY: secrets.meili,
        MEILI_ENV: "production",
        MEILI_NO_ANALYTICS: "true",
      },
    });

    await this.start({
      executable: programs.rustfs,
      args: ["server"],
      environment: {
        RUSTFS_ADDRESS: `127.0.0.1:${ports.objects}`,
        RUSTFS_CONSOLE_ADDRESS: `127.0.0.1:${ports.objectsConsole}`,
        RUSTFS_CONSOLE_ENABLE: "false",
        RUSTFS_VOLUMES: join(state, "objects"),
        RUSTFS_ACCESS_KEY: "librechat",
        RUSTFS_SECRET_KEY_FILE: join(state, "secrets", "objects"),
      },
    });

    process.stderr.write(
      "LibreChat databases are ready. Run librechatctl bootstrap if the personal account has not been created.\n",
    );

    const accountFile = join(state, "account.json");

    await this.readiness.wait(
      () => exists(accountFile),
      AccountBootstrapReadinessError,
      Number.POSITIVE_INFINITY,
    );

    const accountRaw: unknown = JSON.parse(await readFile(accountFile, "utf8"));

    const account = accountSchema.parse(accountRaw);

    const providers = await configureProviders(manifest.providers);

    const credentialSocket = join(socketDirectory, "credentials.sock");

    const credentialServer = await credentialService(
      programs.ironProto,
      async () =>
        (
          await this.processes.run({
            executable: programs.gh,
            args: ["auth", "token", "--hostname", "github.com"],
          })
        ).trim(),
      credentialSocket,
    );

    this.closeCredentials = () => credentialServer.forceShutdown();

    const ironDirectory = join(state, "iron");

    if (!(await exists(join(ironDirectory, "ca.crt")))) {
      await this.processes.run({
        executable: programs.iron,
        args: ["generate-ca", "--outdir", ironDirectory],
      });
    }

    const hostAddresses = Object.values(networkInterfaces())
      .flatMap((interfaces) => interfaces ?? [])
      .map(
        ({ address, family }) => `${address}/${family === "IPv4" ? 32 : 128}`,
      );

    await writePrivateJson(
      join(state, "iron.json"),
      ironConfiguration(
        ironDirectory,
        hostAddresses,
        credentialSocket,
        ports.iron,
      ),
    );

    await this.start({
      executable: programs.iron,
      args: ["--config", join(state, "iron.json")],
    });

    const backend = new QemuBackend({
      executable: programs.qemu,
      boot: {
        architecture: manifest.guest.architecture,
        accelerator: manifest.guest.accelerator,
        forwarder: programs.socat,
        ironPort: ports.iron,
        fileRelayPort: ports.egressGateway,
        archiveBrokerPort: ports.archive,
        memoryMiB: 4096,
        cpus: 2,
      },
      files: new FileVmStorage({
        directory: join(state, "sessions"),
        socketDirectory,
        uid: process.getuid?.() ?? 0,
        image: manifest.guest.image,
        kernel: manifest.guest.kernel,
        initrd: manifest.guest.initrd,
        init: manifest.guest.init,
        checkpointMaxBytes: 512 * 1024 * 1024,
        stopExistingVm,
      }),
      processes: this.processes,
      fetch: fetchSocket,
      delay: async (milliseconds, signal) => {
        await delay(milliseconds, undefined, { signal });
      },
      timeout: (milliseconds) => AbortSignal.timeout(milliseconds),
      newBootId: randomUUID,
      caCertificate: await readFile(join(ironDirectory, "ca.crt"), "utf8"),
      archiveToken: secrets.archive,
      executionPublicKey: executionKey.publicKey,
      onError: (error) => this.failure.resolve(error),
      onFailure: async (session, error) => {
        report(error);

        await this.sessions?.quarantine(
          session.runtimeId,
          "The VM exited unexpectedly; inspect the last checkpoint before resetting it.",
        );
      },
    });

    const sessions = new SessionManager({
      userId: account.userId,
      store: new JsonSessionStore(join(state, "sessions")),
      backend,
      idleMs: 15 * 60 * 1000,
      retentionMs: 30 * 24 * 60 * 60 * 1000,
    });

    this.sessions = sessions;

    const catalogueId = "rt_15373aaf9899b0caebed2c07022005137f42d743";

    const mcp = new McpRouter({
      userId: account.userId,
      token: secrets.controller,
      servers: new Set(manifest.localMcpServers),
      sessions,
      catalogue: () => sessions.acquireCodeRuntime(catalogueId),
      forward: async (guest, server, request) => {
        const init: RequestInit & { duplex: "half" } = {
          method: request.method,
          headers: request.headers,
          body: request.body,
          duplex: "half",
          signal: request.signal,
        };

        return await fetchSocket(
          guest.socket,
          new Request(`http://guest/mcp/${server}`, init),
        );
      },
    });

    const controller = new ControllerRouter({
      userId: account.userId,
      token: secrets.controller,
      sessions,
      mcp,
    });

    const controlServer = httpService({
      handler: (request) => controller.route(request),
      onError: report,
    });

    controlServer.listen(ports.controller, "127.0.0.1");

    const archive = new ArchiveBroker(secrets.archive, async (args) =>
      this.processes.run({ executable: programs.agentsview, args }),
    );

    const archiveServer = httpService({
      handler: (request) => archive.route(request),
      onError: report,
      maxBodyBytes: 16 * 1024,
    });

    archiveServer.listen(ports.archive, "127.0.0.1");

    this.servers = [controlServer, archiveServer];

    for (const server of this.servers) {
      server.on("error", (error) => this.failure.reject(error));
    }

    const codeEnvironment = {
      SERVICE_PORT: String(ports.codeApi),
      REDIS_HOST: "127.0.0.1",
      REDIS_PORT: String(ports.redis),
      REDIS_PASSWORD: secrets.redis,
      MINIO_ENDPOINT: "127.0.0.1",
      MINIO_PORT: String(ports.objects),
      MINIO_USE_SSL: "false",
      MINIO_ACCESS_KEY: "librechat",
      MINIO_SECRET_KEY: secrets.objects,
      MINIO_BUCKET: "codeapi",
      FILE_SERVER_HOST: "127.0.0.1",
      FILE_SERVER_PORT: String(ports.fileServer),
      TOOL_CALL_SERVER_PORT: String(ports.toolServer),
      EGRESS_GATEWAY_PORT: String(ports.egressGateway),
      WORKER_HEALTH_PORT: String(ports.workerHealth),
      FILE_SERVER_URL: `http://127.0.0.1:${ports.fileServer}`,
      TOOL_CALL_SERVER_URL: `http://127.0.0.1:${ports.toolServer}`,
      EGRESS_GATEWAY_URL: `http://127.0.0.1:${ports.egressGateway}`,
      CODEAPI_AUTH_PROVIDER: "librechat-jwt",
      CODEAPI_JWT_PUBLIC_KEY: createPublicKey({
        key: Buffer.from(authKey.publicKey, "base64"),
        format: "der",
        type: "spki",
      })
        .export({ type: "spki", format: "pem" })
        .toString(),
      CODEAPI_JWT_ALGORITHM: "EdDSA",
      CODEAPI_JWT_KID: "dotfiles-codeapi",
      CODEAPI_JWT_ISSUER: "librechat",
      CODEAPI_JWT_AUDIENCE: "codeapi",
      CODEAPI_JWT_SINGLE_TENANT_ID: CODE_TENANT_ID,
      CODEAPI_SANDBOX_BACKEND: "remote-bridge",
      CODEAPI_EXECUTION_PROFILE: "stateful",
      CODEAPI_RUNTIME_SESSION_MODE: "strict",
      CODEAPI_BRIDGE_AUTH_MODE: "static",
      CODEAPI_BRIDGE_DYNAMIC_WORKERS: "false",
      CODEAPI_BRIDGE_WORKER_ID: "librechat-local",
      CODEAPI_BRIDGE_TOKEN: secrets.bridge,
      CODEAPI_INTERNAL_SERVICE_TOKEN: secrets.internal,
      CODEAPI_EGRESS_GRANT_SECRET: secrets.egress,
      CODEAPI_EXECUTION_MANIFEST_PRIVATE_KEY: executionKey.privateKey,
      PTC_MODE: "replay",
    };

    await Promise.all(
      [
        programs.fileServer,
        programs.toolServer,
        programs.egressGateway,
        programs.codeApi,
        programs.codeWorker,
      ].map(async (executable) =>
        this.start({
          executable,
          args: [],
          environment: codeEnvironment,
          directory: join(state, "app"),
        }),
      ),
    );

    await this.readiness.wait(
      () => httpReady(`http://127.0.0.1:${ports.codeApi}/v1/health`),
      CodeApiReadinessError,
    );

    const supervisor = new ConversationRuntimeSupervisor({
      userId: account.userId,
      sessions,
      fetch: fetchSocket,
      verifyManifest: (token) =>
        verifyExecutionManifestWithPublicKey(token, executionKey.publicKey),
      bodyDigest: executionManifestBodySha256,
    });

    const worker = new BridgeWorker({
      codeApiUrl: `http://127.0.0.1:${ports.codeApi}/v1`,
      token: secrets.bridge,
      workerId: "librechat-local",
      runtimeSupervisor: supervisor,
      capabilities: {
        statefulWorkspace: true,
        sandboxProfile: "nsjail",
        runtimes: ["bash", "python", "node", "bun-js", "bun-ts"],
      },
      onError: report,
    });

    this.monitors.push(this.monitor(worker.run(this.signal)));

    const remoteMcp = structuredClone(manifest.mcpServers);

    await Promise.all(
      Object.entries(manifest.mcpHeaderFiles).map(async ([server, headers]) => {
        if (Object.keys(headers).length === 0) {
          return;
        }

        const resolved = await Promise.all(
          Object.entries(headers).map(async ([header, source]) => [
            header,
            `${source.prefix}${await readCredential(source.file, "Generated service")}`,
          ]),
        );

        remoteMcp[server] = {
          ...remoteMcp[server],
          headers: Object.fromEntries(resolved),
        };
      }),
    );

    const localMcp = configureLocalMcp(
      manifest.localMcpServers,
      ports.controller,
    );

    const embeddingEnvironment: Record<string, string> =
      manifest.providers.ollamaUrl === null
        ? {
            EMBEDDINGS_PROVIDER: "openai",
            EMBEDDINGS_MODEL: "text-embedding-3-small",
          }
        : {
            EMBEDDINGS_PROVIDER: "ollama",
            EMBEDDINGS_MODEL: "qwen3-embedding:0.6b",
            OLLAMA_BASE_URL: manifest.providers.ollamaUrl,
          };

    const ragEnabled = hasEmbeddingProvider(manifest.providers);

    if (ragEnabled) {
      await this.start({
        executable: programs.rag,
        args: [],
        environment: {
          ...embeddingEnvironment,
          ...(manifest.providers.ollamaUrl === null &&
          typeof providers.environment.OPENAI_API_KEY === "string"
            ? { OPENAI_API_KEY: providers.environment.OPENAI_API_KEY }
            : {}),
          JWT_SECRET: secrets.jwt,
          RAG_UPLOAD_DIR: join(state, "rag"),
          VECTOR_DB_TYPE: "pgvector",
          DB_HOST: "127.0.0.1",
          DB_PORT: String(ports.postgres),
          POSTGRES_DB: "librechat",
          POSTGRES_USER: "librechat",
          POSTGRES_PASSWORD: secrets.postgres,
        },
      });
    }

    if (ragEnabled) {
      await this.readiness.wait(
        () => httpReady("http://127.0.0.1:3180/health"),
        RagReadinessError,
      );
    }

    const agents = configuredPersonalAgents(
      manifest.providers,
      manifest.models,
    );

    await writePrivateJson(join(state, "librechat.json"), {
      version: "1.3.18",
      cache: true,
      registration: { socialLogins: [] },
      interface: { modelSelect: true },
      endpoints: {
        custom: providers.endpoints.custom.map((endpoint) => ({
          ...endpoint,
          models: {
            ...endpoint.models,
            default: [
              endpoint.name === "Ollama"
                ? manifest.models.ollama
                : manifest.models.openrouter,
            ],
          },
        })),
        agents: {
          allowedProviders: agents.map((agent) => agent.provider),
          capabilities: [
            "execute_code",
            "stateful_code_sessions",
            "tools",
            "deferred_tools",
            "skills",
            ...(ragEnabled ? ["file_search"] : []),
          ],
          statefulCodeSessions: {
            allowedEnvironments: ["conversation"],
            environments: [
              {
                id: CODE_ENVIRONMENT_ID,
                name: "Conversation VM",
                type: "managed",
                baseURL: `http://127.0.0.1:${ports.codeApi}/v1`,
                default: true,
              },
            ],
          },
        },
      },
      mcpServers: { ...remoteMcp, ...localMcp.mcpServers },
      mcpSettings: {
        ...localMcp.mcpSettings,
        authorizationMode: "nonblocking",
      },
    });

    const pluginDirectory = join(state, "plugins", "workspace");

    await writePrivateJson(join(pluginDirectory, "plugin.json"), {
      $schema: "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
      name: "workspace",
      version: "1.0.0",
    });

    await writePrivateJson(
      join(pluginDirectory, "ai.librechat", "hooks", "hooks.json"),
      {
        hooks: Object.fromEntries(
          ["RunStart", "PostToolBatch"].map((event) => [
            event,
            [
              {
                hooks: [
                  {
                    type: "command",
                    command: manifest.hookCommand,
                    timeout: 180,
                  },
                ],
              },
            ],
          ]),
        ),
      },
    );

    await writePrivateJson(join(state, "hook.json"), {
      baseURL: `http://127.0.0.1:${ports.controller}`,
      tokenFile: join(state, "secrets", "controller"),
    });

    const authPrivateKey = createPrivateKey({
      key: Buffer.from(authKey.privateKey, "base64"),
      format: "der",
      type: "pkcs8",
    })
      .export({ type: "pkcs8", format: "pem" })
      .toString();

    await this.start({
      executable: programs.librechat,
      args: [],
      directory: join(state, "app"),
      environment: {
        ...providers.environment,
        HOST: "127.0.0.1",
        PORT: String(ports.librechat),
        CONFIG_PATH: join(state, "librechat.json"),
        MONGO_URI: mongoUri,
        MEILI_HOST: `http://127.0.0.1:${ports.meilisearch}`,
        MEILI_MASTER_KEY: secrets.meili,
        JWT_SECRET: secrets.jwt,
        JWT_REFRESH_SECRET: secrets.refresh,
        CREDS_KEY: secrets.encryption,
        CREDS_IV: secrets.iv.slice(0, 32),
        ALLOW_REGISTRATION: "false",
        ALLOW_EMAIL_LOGIN: "true",
        ALLOW_SOCIAL_LOGIN: "false",
        ALLOW_UNVERIFIED_EMAIL_LOGIN: "false",
        SEARCH: "true",
        USE_REDIS: "true",
        REDIS_URI: `redis://:${secrets.redis}@127.0.0.1:${ports.redis}/1`,
        LIBRECHAT_MCP_TOKEN: secrets.controller,
        DEPLOYMENT_PLUGINS_DIR: join(state, "plugins"),
        DEPLOYMENT_PLUGIN_DATA_DIR: join(state, "plugin-data"),
        DEPLOYMENT_PLUGIN_HOOKS: "true",
        DEPLOYMENT_SKILLS_DIR: manifest.skillsDirectory,
        CODEAPI_JWT_ENABLED: "true",
        CODEAPI_JWT_PRIVATE_KEY: authPrivateKey,
        CODEAPI_JWT_ALGORITHM: "EdDSA",
        CODEAPI_JWT_KID: "dotfiles-codeapi",
        CODEAPI_JWT_ISSUER: "librechat",
        CODEAPI_JWT_AUDIENCE: "codeapi",
        CODEAPI_JWT_SINGLE_TENANT_ID: CODE_TENANT_ID,
        LIBRECHAT_CODE_BASEURL: `http://127.0.0.1:${ports.codeApi}/v1`,
        LIBRECHAT_CODE_BASEURL_STATEFUL: `http://127.0.0.1:${ports.codeApi}/v1`,
        LIBRECHAT_CODE_DEFAULT_PROFILE: "stateful",
        ...(ragEnabled ? { RAG_API_URL: "http://127.0.0.1:3180" } : {}),
      },
    });

    const sweep = setInterval(() => {
      if (this.sweepTask === undefined) {
        this.sweepTask = this.sweep(sessions);
      }
    }, 60_000);

    if (this.signal.aborted) {
      clearInterval(sweep);

      return;
    }

    this.signal.addEventListener("abort", () => clearInterval(sweep), {
      once: true,
    });

    await new Promise<void>((resolve) => {
      this.signal.addEventListener("abort", () => resolve(), { once: true });
    });
  }

  private async drain(): Promise<void> {
    try {
      await this.sessions?.shutdown();
    } catch (error) {
      report(error);

      await delay(error instanceof SessionBusyError ? 1000 : 30_000);

      await this.drain();
    }
  }

  async serve(): Promise<void> {
    const running = this.run();

    try {
      await Promise.race([running, this.waitForFailure()]);
    } finally {
      this.abort.abort();

      await Promise.allSettled([running]);

      await this.sweepTask;

      await this.drain();

      this.closeCredentials?.();

      await Promise.all(
        this.servers.map(
          async (server) =>
            new Promise<void>((resolve) => {
              server.close(() => resolve());

              server.closeAllConnections();
            }),
        ),
      );

      await this.children.toReversed().reduce(async (previous, child) => {
        await previous;

        await child.stop();
      }, Promise.resolve());

      await Promise.all(this.monitors);
    }
  }
}
