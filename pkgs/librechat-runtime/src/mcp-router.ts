import {
  McpConnections,
  discoveryMethods,
  type McpConnectionOptions,
} from "./mcp-connections.ts";
import { timingSafeEqual } from "node:crypto";
import { z } from "zod";
import {
  McpAuthenticationError,
  McpServerError,
  McpHttpMethodError,
  McpPrincipalError,
  McpJsonError,
  McpRequestError,
  McpCatalogueExecutionError,
  mcpErrorResponse,
} from "./errors.ts";
import { runtimeIdentity } from "./identity.ts";
export interface McpRouterOptions extends McpConnectionOptions {
  token: string;
  userId: string;
  servers: ReadonlySet<string>;
}

const rpcSchema = z.union([
  z.object({ jsonrpc: z.literal("2.0"), method: z.string() }),
  z
    .looseObject({
      jsonrpc: z.literal("2.0"),
      id: z.union([z.string(), z.number()]),
    })
    .refine(
      (value) => !("method" in value) && "result" in value !== "error" in value,
    ),
]);

const responseHeaders = [
  "content-type",
  "mcp-session-id",
  "mcp-protocol-version",
  "cache-control",
];

export function authorised(actual: string | null, token: string): boolean {
  const expected = Buffer.from(`Bearer ${token}`);

  const supplied = Buffer.from(actual ?? "");

  return (
    token.length >= 32 &&
    supplied.length === expected.length &&
    timingSafeEqual(supplied, expected)
  );
}

function selectedHeaders(source: Headers, allowed: string[]): Headers {
  const result = new Headers();

  for (const name of allowed) {
    const value = source.get(name);

    if (value !== null) {
      result.set(name, value);
    }
  }

  return result;
}

function leasedBody(
  body: ReadableStream<Uint8Array>,
  release: () => Promise<void>,
): ReadableStream<Uint8Array> {
  const reader = body.getReader();

  let finished = false;

  async function finish(): Promise<void> {
    if (finished) {
      return;
    }

    finished = true;

    await release();
  }

  return new ReadableStream({
    async pull(controller) {
      try {
        const chunk = await reader.read();

        if (chunk.done) {
          await finish();

          controller.close();

          return;
        }

        controller.enqueue(chunk.value);
      } catch (error) {
        await finish();

        controller.error(error);
      }
    },
    async cancel(reason: unknown) {
      try {
        await reader.cancel(reason);
      } finally {
        await finish();
      }
    },
  });
}

export class McpRouter {
  private readonly options: McpRouterOptions;
  private readonly connections: McpConnections;

  constructor(options: McpRouterOptions) {
    this.options = options;
    this.connections = new McpConnections(options);
  }

  async route(request: Request): Promise<Response> {
    if (!authorised(request.headers.get("authorization"), this.options.token)) {
      return mcpErrorResponse(new McpAuthenticationError());
    }

    const path = new URL(request.url).pathname;

    const server = /^\/mcp\/([a-zA-Z0-9_-]+)$/u.exec(path)?.[1];

    if (server === undefined || !this.options.servers.has(server)) {
      return mcpErrorResponse(new McpServerError());
    }

    if (!["POST", "DELETE"].includes(request.method)) {
      return mcpErrorResponse(new McpHttpMethodError());
    }

    const conversation = request.headers.get("x-librechat-conversation-id");

    const user = request.headers.get("x-librechat-user-id");

    const catalogue = conversation === null && user === null;

    if (
      !catalogue &&
      (user !== this.options.userId ||
        !z.uuid().safeParse(conversation).success)
    ) {
      return mcpErrorResponse(new McpPrincipalError());
    }

    request.signal.throwIfAborted();

    let body: string | undefined;
    let method: string | undefined;

    if (request.method === "POST") {
      body = await request.text();

      let payload: unknown;

      try {
        payload = JSON.parse(body);
      } catch {
        return mcpErrorResponse(new McpJsonError());
      }

      const rpc = rpcSchema.safeParse(payload);

      if (!rpc.success) {
        return mcpErrorResponse(new McpRequestError());
      }

      method =
        "method" in rpc.data && typeof rpc.data.method === "string"
          ? rpc.data.method
          : undefined;

      if (
        catalogue &&
        (!("method" in rpc.data) ||
          typeof rpc.data.method !== "string" ||
          !discoveryMethods.has(rpc.data.method))
      ) {
        return mcpErrorResponse(new McpCatalogueExecutionError());
      }
    }

    const runtimeId = catalogue
      ? "catalogue"
      : runtimeIdentity(this.options.userId, conversation ?? "");

    if (user !== null && conversation !== null) {
      await this.options.sessions.register(user, conversation, request.signal);
    }

    const result = await this.connections.route(
      request,
      runtimeId,
      server,
      method,
      body,
    );

    try {
      const headers = selectedHeaders(result.response.headers, responseHeaders);
      headers.delete("mcp-session-id");

      if (result.sessionId !== undefined) {
        headers.set("mcp-session-id", result.sessionId);
      }

      if (result.response.body === null) {
        await result.release();

        return new Response(null, { status: result.response.status, headers });
      }

      return new Response(
        leasedBody(result.response.body, () => result.release()),
        {
          status: result.response.status,
          headers,
        },
      );
    } catch (error) {
      await result.release();

      throw error;
    }
  }
}
