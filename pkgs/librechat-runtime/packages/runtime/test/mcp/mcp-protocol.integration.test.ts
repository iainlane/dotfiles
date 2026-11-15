import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { expect, it } from "vitest";
import { z } from "zod";
import { runtimeIdentity } from "#runtime/platform/identity";
import { McpRouter } from "#runtime/mcp/mcp-router";
import {
  SessionManager,
  type Guest,
  type GuestBackend,
  type Session,
} from "#runtime/sessions/sessions";

interface Client {
  connect(transport: object): Promise<void>;
  listTools(): Promise<unknown>;
  callTool(input: { name: string }): Promise<unknown>;
  close(): Promise<void>;
}

interface ClientTransport {
  terminateSession(): Promise<void>;
}

interface ServerTransport {
  handleRequest(request: Request): Promise<Response>;
}

interface Server {
  connect(transport: ServerTransport): Promise<void>;
  registerTool(
    name: string,
    options: { description: string; inputSchema: Record<string, never> },
    callback: () => Promise<{ content: { type: "text"; text: string }[] }>,
  ): void;
  close(): Promise<void>;
}

class GuestAlreadyRunningError extends Error {
  constructor() {
    super("The fixture guest is already running");
    this.name = "GuestAlreadyRunningError";
  }
}

class FixtureBackend implements GuestBackend {
  readonly running = new Set<string>();
  private readonly now: () => number;

  constructor(now: () => number) {
    this.now = now;
  }

  async start(session: Session): Promise<Guest> {
    if (this.running.has(session.runtimeId)) {
      throw new GuestAlreadyRunningError();
    }

    this.running.add(session.runtimeId);

    return {
      socket: session.runtimeId,
      bootId: `${session.runtimeId}@${this.now()}`,
    };
  }

  async checkpoint(): Promise<void> {}

  async stop(session: Session): Promise<void> {
    this.running.delete(session.runtimeId);
  }

  async remove(): Promise<void> {}
}

class McpSdkFixtureRequiredError extends Error {
  constructor() {
    super(
      "Run tests in nix develop .#librechat-runtime to provide the pinned MCP SDK",
    );
    this.name = "McpSdkFixtureRequiredError";
  }
}

const root = process.env.LIBRECHAT_TEST_ROOT;

if (root === undefined) {
  throw new McpSdkFixtureRequiredError();
}

const require = createRequire(`${root}/package.json`);
const sdkClient = z
  .object({
    Client: z.custom<
      new (
        info: { name: string; version: string },
        options: { capabilities: object },
      ) => Client
    >((value) => typeof value === "function"),
  })
  .parse(require("@modelcontextprotocol/sdk/client/index.js"));
const sdkClientTransport = z
  .object({
    StreamableHTTPClientTransport: z.custom<
      new (
        url: URL,
        options: { requestInit: RequestInit; fetch: typeof fetch },
      ) => ClientTransport
    >((value) => typeof value === "function"),
  })
  .parse(require("@modelcontextprotocol/sdk/client/streamableHttp.js"));
const sdkServer = z
  .object({
    McpServer: z.custom<
      new (info: { name: string; version: string }) => Server
    >((value) => typeof value === "function"),
  })
  .parse(require("@modelcontextprotocol/sdk/server/mcp.js"));
const sdkServerTransport = z
  .object({
    WebStandardStreamableHTTPServerTransport: z.custom<
      new (options: {
        sessionIdGenerator: () => string;
        enableJsonResponse: boolean;
      }) => ServerTransport
    >((value) => typeof value === "function"),
  })
  .parse(
    require("@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js"),
  );

it.each([true, false])(
  "discovers lazily and isolates SDK tool execution with JSON responses %s",
  async (enableJsonResponse) => {
    const userId = "0123456789abcdef01234567";
    const conversations = [
      "ea277865-9bbd-45ec-9cd2-234cf9dc9169",
      "dbd5bc71-a5a0-4363-8672-e84c9ccad80f",
    ];
    const catalogueId = "rt_15373aaf9899b0caebed2c07022005137f42d743";
    const token = "a".repeat(64);
    const records = new Map<string, Session>();
    let clock = 0;
    const backend = new FixtureBackend(() => clock);
    const sessions = new SessionManager({
      userId,
      idleMs: 100,
      retentionMs: 1000,
      now: () => clock,
      store: {
        load: async (id) => records.get(id),
        save: async (session) => {
          records.set(session.runtimeId, structuredClone(session));
        },
        list: async () => [...records.keys()],
      },
      backend,
    });
    const servers: Server[] = [];
    const transports = new Map<
      string,
      { socket: string; transport: ServerTransport }
    >();
    const router = new McpRouter({
      userId,
      token,
      servers: new Set(["git"]),
      sessions,
      catalogue: (signal) => sessions.acquireCodeRuntime(catalogueId, signal),
      catalogueRunning: (signal) =>
        sessions.acquireRunning(catalogueId, signal),
      forward: async (guest, _server, request) => {
        const id = request.headers.get("mcp-session-id");
        let transport = id === null ? undefined : transports.get(id)?.transport;

        if (id === null && request.method === "POST") {
          const server = new sdkServer.McpServer({
            name: "workspace",
            version: "1.0.0",
          });
          server.registerTool(
            "where",
            { description: "Return the workspace identity", inputSchema: {} },
            async () => ({ content: [{ type: "text", text: guest.socket }] }),
          );
          const session = randomUUID();
          transport =
            new sdkServerTransport.WebStandardStreamableHTTPServerTransport({
              sessionIdGenerator: () => session,
              enableJsonResponse,
            });
          servers.push(server);
          transports.set(session, { socket: guest.socket, transport });
          await server.connect(transport);
        }

        if (transport === undefined) {
          return new Response(null, { status: 404 });
        }

        return await transport.handleRequest(request);
      },
    });
    const clients = conversations.map((conversationId) => {
      const client = new sdkClient.Client(
        { name: "librechat-test", version: "1.0.0" },
        { capabilities: {} },
      );
      const transport = new sdkClientTransport.StreamableHTTPClientTransport(
        new URL("http://controller/mcp/git"),
        {
          requestInit: {
            headers: {
              authorization: `Bearer ${token}`,
              "x-librechat-user-id": userId,
              "x-librechat-conversation-id": conversationId,
            },
          },
          fetch: async (input, init) =>
            await router.route(new Request(input, init)),
        },
      );

      return { client, transport };
    });

    try {
      await Promise.all(
        clients.map(async ({ client, transport }) => {
          await client.connect(transport);
          await client.listTools();
        }),
      );
      expect([...backend.running]).toStrictEqual([catalogueId]);

      const results = await Promise.all(
        clients.map(
          async ({ client }) =>
            await Promise.all([
              client.callTool({ name: "where" }),
              client.callTool({ name: "where" }),
            ]),
        ),
      );
      const workspaces = conversations.map((conversation) =>
        runtimeIdentity(userId, conversation),
      );

      expect({
        vms: [...backend.running].toSorted(),
        mcpSessions: [...transports.values()]
          .map(({ socket }) => socket)
          .toSorted(),
        results,
      }).toStrictEqual({
        vms: [catalogueId, ...workspaces].toSorted(),
        mcpSessions: [catalogueId, catalogueId, ...workspaces].toSorted(),
        results: conversations.map((conversation) => [
          {
            content: [
              { type: "text", text: runtimeIdentity(userId, conversation) },
            ],
          },
          {
            content: [
              { type: "text", text: runtimeIdentity(userId, conversation) },
            ],
          },
        ]),
      });

      clock = 101;
      await sessions.sweep();
      await Promise.all(
        clients.map(
          async ({ transport }) => await transport.terminateSession(),
        ),
      );
      expect([...backend.running]).toStrictEqual([]);
    } finally {
      await Promise.all(
        clients.map(async ({ client }) => await client.close()),
      );
      await Promise.all(servers.map(async (server) => await server.close()));
      await sessions.shutdown();
    }
  },
);
