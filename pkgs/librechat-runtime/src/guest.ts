import { callbackify, isDeepStrictEqual } from "node:util";
import { StatusCodes } from "http-status-codes";
import { readFile, stat, chmod } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { z } from "zod";
import { mcpErrorResponse } from "./errors.ts";
import { writePrivateFile } from "./config.ts";
import { httpService } from "./http-server.ts";
import { GuestWorkspaceTrust } from "./guest-trust.ts";
import { GuestServiceProcess } from "./guest-service.ts";
import { SystemdService } from "./systemd-service.ts";
import { httpReady } from "./startup.ts";
import type { ManagedProcess, ProcessRunner } from "./processes.ts";

export const guestSpecificationSchema = z.object({
  runner: z.string(),
  runnerEnvironment: z.record(z.string(), z.string()),
  mcpProxy: z.string(),
  mcpEnvironment: z.record(z.string(), z.string()),
  mcpConfiguration: z.string(),
  caBundle: z.string(),
  systemdRun: z.string(),
  systemctl: z.string(),
  date: z.string(),
  workspace: z.object({
    uid: z.int().positive(),
    gid: z.int().positive(),
    mkdir: z.string(),
    certutil: z.string(),
  }),
});

export type GuestSpecification = z.infer<typeof guestSpecificationSchema>;

const bindingSchema = z.object({
  runtimeId: z.string().regex(/^rt_[a-f0-9]{40}$/u),
  caCertificate: z.string().min(64).max(16384),
  archiveToken: z.string().min(32).max(256),
  executionPublicKey: z.string().min(32).max(16384),
});

type GuestBinding = z.infer<typeof bindingSchema>;

class GuestResumeTimeError extends Error {
  readonly status = StatusCodes.BAD_REQUEST;

  constructor() {
    super("The guest resume time must be a Unix timestamp in milliseconds");
    this.name = "GuestResumeTimeError";
  }
}

interface PendingGuestBinding extends PromiseWithResolvers<void> {
  binding: GuestBinding;
}

export class GuestRunnerStartupError extends Error {
  constructor() {
    super("The guest execution runner did not become ready");

    this.name = "GuestRunnerStartupError";
  }
}

export class GuestWorkspaceInitialisationError extends Error {
  constructor() {
    super(
      "The guest execution runner could not initialise its persistent workspace",
    );

    this.name = "GuestWorkspaceInitialisationError";
  }
}

export class GuestUnboundError extends Error {
  readonly status = StatusCodes.CONFLICT;

  constructor() {
    super("The guest has no runtime binding");

    this.name = "GuestUnboundError";
  }
}

export class GuestBindingFormatError extends Error {
  readonly status = StatusCodes.BAD_REQUEST;

  constructor() {
    super("The guest runtime binding is invalid");

    this.name = "GuestBindingFormatError";
  }
}

export class GuestBindingConflictError extends Error {
  readonly status = StatusCodes.CONFLICT;

  constructor() {
    super("The guest is already bound to a different runtime or credentials");

    this.name = "GuestBindingConflictError";
  }
}

export class GuestRuntimeMismatchError extends Error {
  readonly status = StatusCodes.FORBIDDEN;

  constructor() {
    super("The requested runtime differs from the guest runtime");

    this.name = "GuestRuntimeMismatchError";
  }
}

export class GuestRouteNotFoundError extends Error {
  readonly status = StatusCodes.NOT_FOUND;

  constructor() {
    super("The guest route does not exist");

    this.name = "GuestRouteNotFoundError";
  }
}

export class GuestHttpMethodError extends Error {
  readonly status = StatusCodes.METHOD_NOT_ALLOWED;

  constructor() {
    super("The guest route does not accept this HTTP method");

    this.name = "GuestHttpMethodError";
  }
}

export class GuestMcpStartupError extends Error {
  readonly status = StatusCodes.SERVICE_UNAVAILABLE;

  constructor() {
    super("The guest MCP proxy did not become ready");

    this.name = "GuestMcpStartupError";
  }
}

export interface GuestOperations {
  bind(binding: GuestBinding): Promise<void>;

  resume(time?: number): Promise<void>;

  quiesce(): Promise<void>;

  shutdown(): Promise<void>;

  forward(
    request: Request,
    target: "runner" | "mcp",
    path: string,
  ): Promise<Response>;
}

export class GuestGateway {
  private readonly operations: GuestOperations;
  private binding: GuestBinding | undefined;
  private pendingBinding: PendingGuestBinding | undefined;

  constructor(operations: GuestOperations) {
    this.operations = operations;
  }

  private async bind(binding: GuestBinding): Promise<Response> {
    const current = this.binding ?? this.pendingBinding?.binding;

    if (current !== undefined && !isDeepStrictEqual(current, binding)) {
      return mcpErrorResponse(new GuestBindingConflictError());
    }

    if (this.binding !== undefined) {
      return Response.json({ status: "bound" });
    }

    const launching = this.pendingBinding === undefined;
    const pending = this.pendingBinding ?? {
      binding,
      ...Promise.withResolvers<void>(),
    };

    this.pendingBinding = pending;

    if (launching) {
      try {
        pending.resolve(this.operations.bind(binding));
      } catch (error) {
        pending.reject(error);
      }
    }

    try {
      await pending.promise;

      this.binding = binding;

      return Response.json({ status: "bound" });
    } finally {
      if (this.pendingBinding === pending) {
        this.pendingBinding = undefined;
      }
    }
  }

  async route(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;

    if (path === "/health" && request.method === "GET") {
      return Response.json({
        runtimeId: this.binding?.runtimeId ?? null,
        resumeClock: true,
      });
    }

    if (path === "/control/bind" && request.method === "POST") {
      let raw: unknown;

      try {
        raw = await request.json();
      } catch (error) {
        if (!(error instanceof SyntaxError)) {
          throw error;
        }
      }

      const binding = bindingSchema.safeParse(raw);

      if (!binding.success) {
        return mcpErrorResponse(new GuestBindingFormatError());
      }

      return await this.bind(binding.data);
    }

    if (this.binding === undefined) {
      return mcpErrorResponse(new GuestUnboundError());
    }

    if (request.method === "POST" && path === "/control/resume") {
      const header = request.headers.get("x-librechat-resume-time");
      const time = z
        .string()
        .regex(/^\d+$/u)
        .transform(Number)
        .pipe(z.number().int().nonnegative().max(8640000000000000))
        .optional()
        .safeParse(header ?? undefined);
      if (!time.success) {
        return mcpErrorResponse(new GuestResumeTimeError());
      }
      await this.operations.resume(time.data);

      return Response.json({ status: "ready" });
    }

    if (request.method === "POST" && path === "/control/quiesce") {
      await this.operations.quiesce();

      return Response.json({ status: "quiesced" });
    }

    if (request.method === "POST" && path === "/control/shutdown") {
      await this.operations.shutdown();

      return Response.json({ status: "stopping" });
    }

    if (
      /^\/runner\/api\/v2\/(execute|workspace\/execute|session\/checkpoint|session\/restore)$/u.test(
        path,
      )
    ) {
      if (
        request.headers.get("x-runtime-session-id") !== this.binding.runtimeId
      ) {
        return mcpErrorResponse(new GuestRuntimeMismatchError());
      }

      const method = path.endsWith("/checkpoint") ? "GET" : "POST";

      if (request.method !== method) {
        return mcpErrorResponse(new GuestHttpMethodError());
      }

      return await this.operations.forward(
        request,
        "runner",
        path.slice("/runner".length),
      );
    }

    const server = /^\/mcp\/([a-zA-Z0-9_-]+)$/u.exec(path)?.[1];

    if (server !== undefined) {
      return await this.operations.forward(
        request,
        "mcp",
        `/servers/${server}/mcp`,
      );
    }

    return mcpErrorResponse(new GuestRouteNotFoundError());
  }
}

export class NodeGuestOperations implements GuestOperations {
  private readonly specification: GuestSpecification;
  private readonly processes: ProcessRunner;
  private readonly fetch: typeof globalThis.fetch;
  private readonly onError: (error: unknown) => void;
  private readonly mcp: GuestServiceProcess;
  private readonly runner: GuestServiceProcess;
  private binding: GuestBinding | undefined;

  constructor(
    specification: GuestSpecification,
    processes: ProcessRunner,
    options: { fetch: typeof globalThis.fetch; onError(error: unknown): void },
  ) {
    this.specification = specification;

    this.processes = processes;

    this.fetch = options.fetch;

    this.onError = (error) => options.onError(error);

    this.runner = new GuestServiceProcess({
      start: (command) => this.processes.start(command),
      stop: (child) => child.stop(),
    });

    const mcpService = new SystemdService(
      {
        systemctl: this.specification.systemctl,
        unit: "librechat-mcp.service",
      },
      this.processes,
    );

    this.mcp = new GuestServiceProcess({
      start: (command) => this.processes.start(command),
      stop: (child) => mcpService.stop(child),
    });
  }

  private async waitForRunner(
    child: ManagedProcess,
    remaining = 30,
  ): Promise<void> {
    if (remaining === 0 || !child.running()) {
      throw new GuestRunnerStartupError();
    }

    if (
      await httpReady("http://127.0.0.1:2000/api/v2/health", {
        fetch: this.fetch,
        timeoutMs: 1000,
      })
    ) {
      return;
    }

    await delay(1000);

    await this.waitForRunner(child, remaining - 1);
  }

  private async watchRunner(child: ManagedProcess): Promise<void> {
    try {
      await child.exited;
    } catch {
      await this.processes.run({
        executable: this.specification.systemctl,
        args: ["poweroff", "--no-block"],
      });
    }
  }

  async bind(binding: GuestBinding): Promise<void> {
    if (this.binding !== undefined) {
      return;
    }

    const bundle = await readFile(this.specification.caBundle, "utf8");

    await writePrivateFile(
      "/run/librechat-guest/ca-bundle.crt",
      `${bundle}\n${binding.caCertificate}`,
    );

    await writePrivateFile(
      "/run/librechat-guest/archive-token",
      binding.archiveToken,
    );

    await writePrivateFile(
      "/run/librechat-guest/iron-ca.crt",
      binding.caCertificate,
    );

    await chmod("/run/librechat-guest", 0o755);

    await Promise.all([
      chmod("/run/librechat-guest/iron-ca.crt", 0o444),
      chmod("/run/librechat-guest/ca-bundle.crt", 0o444),
      chmod("/run/librechat-guest/archive-token", 0o444),
    ]);

    await this.runner.start(
      {
        executable: this.specification.runner,
        args: [],
        environment: {
          ...this.specification.runnerEnvironment,
          SANDBOX_EXECUTION_MANIFEST_PUBLIC_KEY: binding.executionPublicKey,
        },
      },
      async (child) => {
        callbackify(() => this.watchRunner(child))((error) => {
          if (error !== null) {
            this.onError(error);
          }
        });

        await this.waitForRunner(child);

        const response = await this.fetch(
          "http://127.0.0.1:2000/api/v2/session/checkpoint",
          {
            headers: { "x-runtime-session-id": binding.runtimeId },
            signal: AbortSignal.timeout(30_000),
          },
        );

        if (!response.ok) {
          await response.body?.cancel();

          throw new GuestWorkspaceInitialisationError();
        }

        await response.arrayBuffer();
      },
    );

    this.binding = binding;
  }

  async resume(time?: number): Promise<void> {
    if (this.binding === undefined) {
      throw new GuestUnboundError();
    }

    if (time !== undefined) {
      await this.processes.run({
        executable: this.specification.date,
        args: ["--set", `@${time / 1000}`],
      });
    }

    if (this.mcp.isReady()) {
      return;
    }

    const workspace = await new GuestWorkspaceTrust(
      this.specification.workspace,
      {
        inspect: async () => {
          const state = await stat("/work");

          return {
            uid: state.uid,
            gid: state.gid,
            directory: state.isDirectory(),
          };
        },
        databaseExists: async () => {
          try {
            await stat("/work/.pki/nssdb/cert9.db");

            return true;
          } catch (error) {
            if (
              error instanceof Error &&
              "code" in error &&
              error.code === "ENOENT"
            ) {
              return false;
            }

            throw error;
          }
        },
        run: (command) => this.processes.run(command),
      },
    ).prepare();

    const configuration = z
      .object({ mcpServers: z.record(z.string(), z.unknown()) })
      .parse(
        JSON.parse(await readFile(this.specification.mcpConfiguration, "utf8")),
      );
    if (Object.keys(configuration.mcpServers).length === 0) {
      return;
    }

    const environment = {
      ...this.specification.mcpEnvironment,
      HOME: "/work",
      AGENTSVIEW_BROKER_TOKEN: this.binding.archiveToken,
    };

    await this.mcp.start(
      {
        executable: this.specification.systemdRun,
        args: [
          "--unit=librechat-mcp",
          "--collect",
          "--wait",
          "--pipe",
          "--property=KillMode=control-group",
          `--uid=${workspace.uid}`,
          `--gid=${workspace.gid}`,
          "--working-directory=/work",
          ...Object.entries(environment).map(
            ([key, value]) => `--setenv=${key}=${value}`,
          ),
          this.specification.mcpProxy,
          "--pass-environment",
          "--named-server-config",
          this.specification.mcpConfiguration,
          "--host",
          "127.0.0.1",
          "--port",
          "8081",
        ],
      },
      (child) => this.waitForMcp(child),
    );
  }

  private async waitForMcp(
    child: ManagedProcess,
    remaining = 30,
  ): Promise<void> {
    if (remaining === 0 || !child.running()) {
      throw new GuestMcpStartupError();
    }

    if (
      await httpReady("http://127.0.0.1:8081/status", {
        fetch: this.fetch,
        timeoutMs: 1000,
      })
    ) {
      return;
    }

    await delay(1000);

    await this.waitForMcp(child, remaining - 1);
  }

  async quiesce(): Promise<void> {
    await this.mcp.stop();
  }

  async shutdown(): Promise<void> {
    await this.quiesce();

    await this.processes.run({
      executable: this.specification.systemctl,
      args: ["poweroff", "--no-block"],
    });
  }

  async forward(
    request: Request,
    target: "runner" | "mcp",
    path: string,
  ): Promise<Response> {
    const port = target === "runner" ? 2000 : 8081;

    const headers = new Headers(request.headers);

    const connectionHeaders =
      headers
        .get("connection")
        ?.split(",")
        .map((header) => header.trim())
        .filter((header) => header.length > 0) ?? [];

    for (const header of [
      "host",
      "connection",
      "keep-alive",
      "proxy-authenticate",
      "proxy-authorization",
      "te",
      "trailer",
      "transfer-encoding",
      "upgrade",
      ...connectionHeaders,
    ]) {
      headers.delete(header);
    }

    const init: RequestInit & { duplex: "half" } = {
      method: request.method,
      headers,
      body: request.body,
      duplex: "half",
      signal: request.signal,
      redirect: "manual",
    };

    return await this.fetch(`http://127.0.0.1:${port}${path}`, init);
  }
}

export function guestHttpService(
  operations: GuestOperations,
  onError: (error: unknown) => void,
): ReturnType<typeof httpService> {
  const gateway = new GuestGateway(operations);

  return httpService({
    handler: (request) => gateway.route(request),
    onError,
    maxBodyBytes: 512 * 1024 * 1024,
  });
}
