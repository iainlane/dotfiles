import { randomUUID } from "node:crypto";
import { z } from "zod";
import { StatusCodes } from "http-status-codes";
import { McpSessionError, mcpErrorResponse } from "./errors.ts";
import type { Guest, SessionLease, SessionManager } from "./sessions.ts";

interface Binding {
  bootId: string;
  sessionId: string | null;
}

interface Connection {
  runtimeId: string;
  server: string;
  initialization: string;
  headers: Headers;
  catalogue: Binding;
  execution?: Binding;
}

const initializeResult = z.object({
  result: z.object({ protocolVersion: z.string() }),
});

async function initializedVersion(response: Response): Promise<string> {
  const text = await response.text();
  const messages =
    response.headers.get("content-type")?.includes("text/event-stream") === true
      ? text
          .split(/\r?\n\r?\n/u)
          .map((event) =>
            event
              .split(/\r?\n/u)
              .filter((line) => line.startsWith("data:"))
              .map((line) => line.slice(5).trimStart())
              .join("\n"),
          )
          .filter(Boolean)
      : [text];

  for (const message of messages) {
    let raw: unknown;

    try {
      raw = JSON.parse(message);
    } catch (error) {
      if (!(error instanceof SyntaxError)) {
        throw error;
      }

      continue;
    }

    const result = initializeResult.safeParse(raw);

    if (result.success) {
      return result.data.result.protocolVersion;
    }
  }

  throw new McpSessionError();
}

export const discoveryMethods = new Set([
  "initialize",
  "notifications/initialized",
  "ping",
  "logging/setLevel",
  "tools/list",
  "resources/list",
  "resources/templates/list",
  "prompts/list",
]);

function routingHeaders(source: Headers): Headers {
  const result = new Headers();

  for (const name of [
    "accept",
    "content-type",
    "mcp-protocol-version",
    "last-event-id",
  ]) {
    const value = source.get(name);

    if (value !== null) {
      result.set(name, value);
    }
  }

  return result;
}

function backendRequest(
  request: Request,
  sessionId: string | null,
  body?: string,
): Request {
  const headers = routingHeaders(request.headers);

  if (sessionId !== null) {
    headers.set("mcp-session-id", sessionId);
  }

  return new Request(request.url, {
    method: request.method,
    headers,
    body,
    signal: request.signal,
  });
}

export interface McpConnectionOptions {
  sessions: Pick<SessionManager, "register" | "acquire" | "acquireRunning">;
  catalogue(signal?: AbortSignal): Promise<SessionLease>;
  catalogueRunning(signal?: AbortSignal): Promise<SessionLease | null>;
  forward(guest: Guest, server: string, request: Request): Promise<Response>;
}

interface McpConnectionResponse {
  response: Response;
  sessionId?: string;
  release(): Promise<void>;
}

export class McpConnections {
  private readonly options: McpConnectionOptions;
  private readonly connections = new Map<string, Connection>();
  private readonly locks = new Map<string, Promise<unknown>>();

  constructor(options: McpConnectionOptions) {
    this.options = options;
  }

  private async locked<T>(id: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.locks.get(id) ?? Promise.resolve();
    const current = this.after(previous, operation);
    this.locks.set(id, current);

    try {
      return await current;
    } finally {
      if (this.locks.get(id) === current) {
        this.locks.delete(id);
      }
    }
  }

  private async after<T>(
    previous: Promise<unknown>,
    operation: () => Promise<T>,
  ): Promise<T> {
    await Promise.allSettled([previous]);

    return await operation();
  }

  async route(
    request: Request,
    runtimeId: string,
    server: string,
    method: string | undefined,
    body?: string,
  ): Promise<McpConnectionResponse> {
    const id = request.headers.get("mcp-session-id");

    if (method === "initialize" && id === null && body !== undefined) {
      return await this.initialize(request, runtimeId, server, body);
    }

    if (id === null) {
      return this.missing();
    }

    return await this.locked(id, async () => {
      request.signal.throwIfAborted();
      const connection = this.connections.get(id);

      if (connection?.runtimeId !== runtimeId || connection.server !== server) {
        return this.missing();
      }

      if (request.method === "DELETE") {
        this.connections.delete(id);
        await this.close(request, connection);

        return {
          response: new Response(null, { status: StatusCodes.NO_CONTENT }),
          release: async () => {},
        };
      }

      const metadataOperation =
        method === undefined ||
        discoveryMethods.has(method) ||
        method.startsWith("notifications/");
      const discovery = connection.execution === undefined && metadataOperation;
      const lease = await this.acquire(
        connection,
        metadataOperation,
        request.signal,
      );

      if (lease === null) {
        this.connections.delete(id);

        return this.missing();
      }

      try {
        request.signal.throwIfAborted();
        let binding = discovery ? connection.catalogue : connection.execution;

        if (binding === undefined) {
          binding = await this.startExecution(request, connection, lease);
          connection.execution = binding;
        }

        if (binding.bootId !== lease.guest.bootId) {
          this.connections.delete(id);
          await lease.release();

          return this.missing();
        }

        const response = await this.options.forward(
          lease.guest,
          server,
          backendRequest(request, binding.sessionId, body),
        );

        return { response, sessionId: id, release: () => lease.release() };
      } catch (error) {
        await lease.release();

        if (error instanceof McpSessionError) {
          this.connections.delete(id);

          return this.missing();
        }

        throw error;
      }
    });
  }

  private async acquire(
    connection: Connection,
    metadataOperation: boolean,
    signal: AbortSignal,
  ): Promise<SessionLease | null> {
    if (!metadataOperation) {
      return await this.options.sessions.acquire(connection.runtimeId, signal);
    }

    if (connection.execution === undefined) {
      return await this.options.catalogueRunning(signal);
    }

    return await this.options.sessions.acquireRunning(
      connection.runtimeId,
      signal,
    );
  }

  private missing(): McpConnectionResponse {
    return {
      response: mcpErrorResponse(new McpSessionError()),
      release: async () => {},
    };
  }

  private async initialize(
    request: Request,
    runtimeId: string,
    server: string,
    body: string,
  ): Promise<McpConnectionResponse> {
    const lease = await this.options.catalogue(request.signal);

    try {
      request.signal.throwIfAborted();
      const response = await this.options.forward(
        lease.guest,
        server,
        backendRequest(request, null, body),
      );

      if (!response.ok) {
        return { response, release: () => lease.release() };
      }

      const id = randomUUID();
      this.connections.set(id, {
        runtimeId,
        server,
        initialization: body,
        headers: routingHeaders(request.headers),
        catalogue: {
          bootId: lease.guest.bootId,
          sessionId: response.headers.get("mcp-session-id"),
        },
      });

      return { response, sessionId: id, release: () => lease.release() };
    } catch (error) {
      await lease.release();

      throw error;
    }
  }

  private async startExecution(
    request: Request,
    connection: Connection,
    lease: SessionLease,
  ): Promise<Binding> {
    const initialize = new Request(`http://guest/mcp/${connection.server}`, {
      method: "POST",
      headers: connection.headers,
      body: connection.initialization,
      signal: request.signal,
    });
    const response = await this.options.forward(
      lease.guest,
      connection.server,
      initialize,
    );

    if (!response.ok) {
      await response.body?.cancel();

      throw new McpSessionError();
    }

    const binding = {
      bootId: lease.guest.bootId,
      sessionId: response.headers.get("mcp-session-id"),
    };
    const version = await initializedVersion(response);
    const notification = new Request(initialize.url, {
      method: "POST",
      headers: routingHeaders(request.headers),
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "notifications/initialized",
      }),
      signal: request.signal,
    });
    notification.headers.set("mcp-protocol-version", version);

    const initialized = await this.options.forward(
      lease.guest,
      connection.server,
      backendRequest(
        notification,
        binding.sessionId,
        await notification.text(),
      ),
    );
    await initialized.body?.cancel();

    if (!initialized.ok) {
      throw new McpSessionError();
    }

    return binding;
  }

  private async close(request: Request, connection: Connection): Promise<void> {
    const catalogue = await this.options.catalogueRunning(request.signal);

    if (catalogue !== null) {
      try {
        await this.closeBinding(
          request,
          connection.server,
          catalogue,
          connection.catalogue,
        );
      } finally {
        await catalogue.release();
      }
    }

    if (connection.execution === undefined) {
      return;
    }

    const execution = await this.options.sessions.acquireRunning(
      connection.runtimeId,
      request.signal,
    );

    if (execution === null) {
      return;
    }

    try {
      await this.closeBinding(
        request,
        connection.server,
        execution,
        connection.execution,
      );
    } finally {
      await execution.release();
    }
  }

  private async closeBinding(
    request: Request,
    server: string,
    lease: SessionLease,
    binding: Binding,
  ): Promise<void> {
    if (binding.bootId !== lease.guest.bootId || binding.sessionId === null) {
      return;
    }

    const response = await this.options.forward(
      lease.guest,
      server,
      backendRequest(request, binding.sessionId),
    );
    await response.body?.cancel();
  }
}
