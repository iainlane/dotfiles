import { createRequire } from "node:module";
import { expect, it } from "vitest";
import { z } from "zod";
import { runtimeIdentity } from "../src/identity.ts";
import { McpRouter } from "../src/mcp-router.ts";
import { SessionManager, type Session } from "../src/sessions.ts";

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

const root = process.env.LIBRECHAT_TEST_ROOT;

if (root === undefined) {
  throw new Error(
    "Run tests in nix develop .#librechat-runtime to provide the pinned MCP SDK",
  );
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
    const starts: string[] = [];
    let clock = 0;
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
      backend: {
        start: async (session) => {
          starts.push(session.runtimeId);
          return {
            socket: session.runtimeId,
            bootId: `${session.runtimeId}-${starts.length}`,
          };
        },
        checkpoint: async () => {},
        stop: async () => {},
        remove: async () => {},
      },
    });
    const servers: Server[] = [];
    const transports = new Map<string, ServerTransport>();
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
        let transport = id === null ? undefined : transports.get(id);

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
          const session = `${guest.bootId}-${servers.length}`;
          transport =
            new sdkServerTransport.WebStandardStreamableHTTPServerTransport({
              sessionIdGenerator: () => session,
              enableJsonResponse,
            });
          servers.push(server);
          transports.set(session, transport);
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
      expect(starts).toStrictEqual([catalogueId]);

      const results = await Promise.all(
        clients.map(
          async ({ client }) =>
            await Promise.all([
              client.callTool({ name: "where" }),
              client.callTool({ name: "where" }),
            ]),
        ),
      );
      expect({ starts, results }).toStrictEqual({
        starts: [
          catalogueId,
          ...conversations.map((conversation) =>
            runtimeIdentity(userId, conversation),
          ),
        ],
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

      expect(servers).toHaveLength(4);

      clock = 101;
      await sessions.sweep();
      await Promise.all(
        clients.map(
          async ({ transport }) => await transport.terminateSession(),
        ),
      );
      expect(starts).toStrictEqual([
        catalogueId,
        ...conversations.map((conversation) =>
          runtimeIdentity(userId, conversation),
        ),
      ]);
    } finally {
      await Promise.all(
        clients.map(async ({ client }) => await client.close()),
      );
      await Promise.all(servers.map(async (server) => await server.close()));
      await sessions.shutdown();
    }
  },
);
