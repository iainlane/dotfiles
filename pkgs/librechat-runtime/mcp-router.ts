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
  McpSessionError,
  mcpErrorResponse,
} from "./errors.ts";
import { runtimeIdentity } from "./identity.ts";
import type { Guest, SessionLease } from "./sessions.ts";

interface LeaseProvider {
  acquire(runtimeId: string): Promise<SessionLease>;
}

export interface McpRouterOptions {
  token: string;
  userId: string;
  servers: ReadonlySet<string>;
  sessions: LeaseProvider;

  catalogue(): Promise<SessionLease>;

  forward(guest: Guest, server: string, request: Request): Promise<Response>;
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

const discoveryMethods = new Set([
  "initialize",
  "notifications/initialized",
  "ping",
  "tools/list",
  "resources/list",
  "resources/templates/list",
  "prompts/list",
]);

const routingHeaders = [
  "accept",
  "content-type",
  "mcp-protocol-version",
  "mcp-session-id",
  "last-event-id",
];

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
  private readonly bindings = new Map<string, string>();

  constructor(options: McpRouterOptions) {
    this.options = options;
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

    let body: string | undefined;

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
    const lease = catalogue
      ? await this.options.catalogue()
      : await this.options.sessions.acquire(runtimeId);
    const sessionId = request.headers.get("mcp-session-id");

    const bindingPrefix = `${runtimeId}:${server}:`;

    const binding = `${bindingPrefix}${sessionId ?? ""}`;

    if (
      sessionId !== null &&
      this.bindings.get(binding) !== lease.guest.bootId
    ) {
      await lease.release();

      return mcpErrorResponse(new McpSessionError());
    }

    const upstream = new Request(`http://guest/mcp/${server}`, {
      method: request.method,
      headers: selectedHeaders(request.headers, routingHeaders),
      body,
      signal: request.signal,
    });

    try {
      const response = await this.options.forward(
        lease.guest,
        server,
        upstream,
      );

      const createdSession = response.headers.get("mcp-session-id");

      if (createdSession !== null && response.ok) {
        this.bindings.set(
          `${bindingPrefix}${createdSession}`,
          lease.guest.bootId,
        );
      }

      if (request.method === "DELETE" && response.ok) {
        this.bindings.delete(binding);
      }

      if (response.body === null) {
        await lease.release();

        return new Response(null, {
          status: response.status,
          headers: selectedHeaders(response.headers, responseHeaders),
        });
      }

      return new Response(
        leasedBody(response.body, () => lease.release()),
        {
          status: response.status,
          headers: selectedHeaders(response.headers, responseHeaders),
        },
      );
    } catch (error) {
      await lease.release();

      throw error;
    }
  }
}
