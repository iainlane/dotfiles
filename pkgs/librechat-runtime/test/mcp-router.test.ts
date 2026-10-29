import { runtimeIdentity } from "../src/identity.ts";
import { configureLocalMcp } from "../src/config.ts";
import { z } from "zod";
import { StatusCodes } from "http-status-codes";
import { beforeEach, expect, it } from "vitest";
import { McpRouter, type McpRouterOptions } from "../src/mcp-router.ts";
import {
  SessionManager,
  type Guest,
  type Session,
  type SessionLease,
} from "../src/sessions.ts";

const token = "a".repeat(64);

const user = "0123456789abcdef01234567";

const conversation = "ea277865-9bbd-45ec-9cd2-234cf9dc9169";

let forwarded: {
  server: string;
  headers: Record<string, string>;
  body: string;
}[];

let released: number;

let boot: string;

let options: McpRouterOptions;

async function lease(): Promise<SessionLease> {
  return {
    session: {
      runtimeId: "test",
      conversationId: conversation,
      userId: user,
      generation: 1,
      lastUsed: 0,
      checkpoint: false,
      expired: false,
      resetReason: "",
      quarantine: null,
    },
    guest: { socket: "private-socket", bootId: boot },
    release: async () => {
      released += 1;
    },
  };
}

async function catalogueLease(): Promise<SessionLease> {
  return {
    ...(await lease()),
    guest: { socket: "catalogue", bootId: "catalogue-boot" },
  };
}

async function forward(
  _guest: Guest,
  server: string,
  request: Request,
): Promise<Response> {
  forwarded.push({
    server,
    headers: Object.fromEntries(request.headers),
    body: await request.text(),
  });

  return Response.json(
    { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-03-26" } },
    { headers: { "mcp-session-id": "backend-session" } },
  );
}

beforeEach(() => {
  forwarded = [];

  released = 0;

  boot = "first-boot";

  options = {
    token,
    userId: user,
    servers: new Set(["git"]),
    sessions: {
      register: async () => (await lease()).session,
      acquire: lease,
      acquireRunning: lease,
    },
    catalogue: lease,
    catalogueRunning: lease,
    forward,
  };
});

function mcpRequest(
  method: string,
  catalogue = false,
  headers: Record<string, string> = {},
): Request {
  return new Request("http://controller/mcp/git", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      ...(catalogue
        ? {}
        : {
            "x-librechat-user-id": user,
            "x-librechat-conversation-id": conversation,
          }),
      ...headers,
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method }),
  });
}

it("initialises tools before the conversation hook has registered a workspace", async () => {
  const records = new Map<string, Session>();
  const sessions = new SessionManager({
    userId: user,
    idleMs: 100,
    retentionMs: 1000,
    now: () => 0,
    store: {
      load: async (id) => records.get(id),
      save: async (session) => {
        records.set(session.runtimeId, structuredClone(session));
      },
      list: async () => [...records.keys()],
    },
    backend: {
      start: async () => ({ socket: "private-socket", bootId: "first-boot" }),
      checkpoint: async () => {},
      stop: async () => {},
      remove: async () => {},
    },
  });

  try {
    const response = await new McpRouter({ ...options, sessions }).route(
      mcpRequest("initialize"),
    );
    const body: unknown = await response.json();

    expect({
      status: response.status,
      body,
      workspaces: [...records.values()].map(({ userId, conversationId }) => ({
        userId,
        conversationId,
      })),
    }).toStrictEqual({
      status: StatusCodes.OK,
      body: {
        jsonrpc: "2.0",
        id: 1,
        result: { protocolVersion: "2025-03-26" },
      },
      workspaces: [{ userId: user, conversationId: conversation }],
    });
  } finally {
    await sessions.shutdown();
  }
});

it("does not register or boot a workspace for an aborted MCP request", async () => {
  const records = new Map<string, Session>();
  let starts = 0;
  const sessions = new SessionManager({
    userId: user,
    idleMs: 100,
    retentionMs: 1000,
    store: {
      load: async (id) => records.get(id),
      save: async (session) => {
        records.set(session.runtimeId, structuredClone(session));
      },
      list: async () => [...records.keys()],
    },
    backend: {
      start: async () => {
        starts += 1;
        return { socket: "private-socket", bootId: "first-boot" };
      },
      checkpoint: async () => {},
      stop: async () => {},
      remove: async () => {},
    },
  });
  const reason = new DOMException("MCP request cancelled", "AbortError");
  const request = new Request(mcpRequest("initialize"), {
    signal: AbortSignal.abort(reason),
  });

  try {
    const [result] = await Promise.allSettled([
      new McpRouter({ ...options, sessions }).route(request),
    ]);
    if (result?.status === "fulfilled") {
      await result.value.body?.cancel();
    }

    expect({ result, records: [...records], starts, forwarded }).toStrictEqual({
      result: { status: "rejected", reason },
      records: [],
      starts: 0,
      forwarded: [],
    });
  } finally {
    await sessions.shutdown();
  }
});

it.each(["tools/call", "resources/read", "prompts/get"])(
  "rejects %s on catalogue connections",
  async (method) => {
    const response = await new McpRouter(options).route(
      mcpRequest(method, true),
    );

    expect({ status: response.status, forwarded }).toStrictEqual({
      status: StatusCodes.FORBIDDEN,
      forwarded: [],
    });
  },
);

it("authenticates before acquiring a VM", async () => {
  const response = await new McpRouter(options).route(
    mcpRequest("initialize", false, { authorization: "Bearer wrong" }),
  );

  expect({ status: response.status, forwarded, released }).toStrictEqual({
    status: StatusCodes.UNAUTHORIZED,
    forwarded: [],
    released: 0,
  });
});

it("strips host credentials and routing headers before forwarding", async () => {
  const response = await new McpRouter(options).route(mcpRequest("initialize"));

  await response.text();

  expect({ forwarded, released }).toStrictEqual({
    forwarded: [
      {
        server: "git",
        headers: { "content-type": "application/json" },
        body: '{"jsonrpc":"2.0","id":1,"method":"initialize"}',
      },
    ],
    released: 1,
  });
});

it("rejects stale sessions after a VM restart without replaying a call", async () => {
  const router = new McpRouter(options);

  const initial = await router.route(mcpRequest("initialize"));
  await initial.text();
  const headers = {
    "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
  };
  await (await router.route(mcpRequest("tools/call", false, headers))).text();

  boot = "second-boot";

  const response = await router.route(mcpRequest("tools/call", false, headers));

  expect({
    status: response.status,
    forwards: forwarded.length,
    released,
  }).toStrictEqual({ status: StatusCodes.NOT_FOUND, forwards: 4, released: 3 });
});

it("rejects session reuse by another conversation", async () => {
  const router = new McpRouter(options);

  const initial = await router.route(mcpRequest("initialize"));
  await initial.text();

  const response = await router.route(
    mcpRequest("tools/call", false, {
      "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
      "x-librechat-conversation-id": "dbd5bc71-a5a0-4363-8672-e84c9ccad80f",
    }),
  );

  expect({ status: response.status, forwards: forwarded.length }).toStrictEqual(
    { status: StatusCodes.NOT_FOUND, forwards: 1 },
  );
});

it("rejects catalogue event streams before acquiring a VM", async () => {
  const request = new Request("http://controller/mcp/git", {
    headers: { authorization: `Bearer ${token}`, accept: "text/event-stream" },
  });

  const response = await new McpRouter(options).route(request);

  expect({ status: response.status, forwarded, released }).toStrictEqual({
    status: StatusCodes.METHOD_NOT_ALLOWED,
    forwarded: [],
    released: 0,
  });
});

it("forwards client replies to server requests within the bound conversation", async () => {
  const router = new McpRouter(options);

  const initial = await router.route(mcpRequest("initialize"));
  await initial.text();

  const original = mcpRequest("initialize", false, {
    "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
  });

  const reply = { jsonrpc: "2.0", id: "roots", result: { roots: [] } };

  const response = await router.route(
    new Request(original.url, {
      method: "POST",
      headers: original.headers,
      body: JSON.stringify(reply),
    }),
  );

  await response.text();

  expect({
    status: response.status,
    reply: forwarded.at(-1)?.body,
    released,
  }).toStrictEqual({
    status: StatusCodes.OK,
    reply: JSON.stringify(reply),
    released: 2,
  });
});

it("permits only the local gateway address for configured stdio servers", () => {
  expect(configureLocalMcp(["git"])).toStrictEqual({
    mcpSettings: { allowedAddresses: ["127.0.0.1:3193"] },
    mcpServers: {
      git: {
        type: "streamable-http",
        url: "http://127.0.0.1:3193/mcp/git",
        requiresOAuth: false,
        headers: { Authorization: "Bearer ${LIBRECHAT_MCP_TOKEN}" },
        requestHeaders: {
          "X-LibreChat-User-ID": "{{LIBRECHAT_USER_ID}}",
          "X-LibreChat-Conversation-ID": "{{LIBRECHAT_BODY_CONVERSATIONID}}",
        },
        serverInstructions: true,
      },
    },
  });
});

it("does not permit loopback addresses without local stdio servers", () => {
  expect(configureLocalMcp([])).toStrictEqual({
    mcpSettings: { allowedAddresses: [] },
    mcpServers: {},
  });
});

it.each(["tools/list", "ping"])(
  "keeps discovery lazy before execution and after idle %s",
  async (method) => {
    const records = new Map<string, Session>();
    let clock = 0;
    const starts: string[] = [];
    const destinations: {
      socket: string;
      method: string;
      session: string | null;
    }[] = [];
    const sessions = new SessionManager({
      userId: user,
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
          return { socket: "conversation", bootId: "conversation-boot" };
        },
        checkpoint: async () => {},
        stop: async () => {},
        remove: async () => {},
      },
    });
    const router = new McpRouter({
      ...options,
      sessions,
      catalogue: catalogueLease,
      catalogueRunning: catalogueLease,
      forward: async (guest, _server, request) => {
        const rpc = z
          .object({ method: z.string() })
          .parse(await request.json());
        destinations.push({
          socket: guest.socket,
          method: rpc.method,
          session: request.headers.get("mcp-session-id"),
        });
        return Response.json(
          { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-03-26" } },
          {
            headers:
              rpc.method === "initialize"
                ? { "mcp-session-id": `${guest.socket}-session` }
                : {},
          },
        );
      },
    });

    try {
      const initialized = await router.route(mcpRequest("initialize"));
      await initialized.text();
      const session = initialized.headers.get("mcp-session-id");
      expect(session).not.toBeNull();
      const headers = { "mcp-session-id": session ?? "" };
      await (
        await router.route(
          mcpRequest("notifications/initialized", false, headers),
        )
      ).text();
      await (
        await router.route(mcpRequest("tools/list", false, headers))
      ).text();
      expect({ starts, destinations }).toStrictEqual({
        starts: [],
        destinations: [
          { socket: "catalogue", method: "initialize", session: null },
          {
            socket: "catalogue",
            method: "notifications/initialized",
            session: "catalogue-session",
          },
          {
            socket: "catalogue",
            method: "tools/list",
            session: "catalogue-session",
          },
        ],
      });
      await (
        await router.route(mcpRequest("tools/call", false, headers))
      ).text();
      expect({ starts, destinations: destinations.slice(3) }).toStrictEqual({
        starts: [runtimeIdentity(user, conversation)],
        destinations: [
          { socket: "conversation", method: "initialize", session: null },
          {
            socket: "conversation",
            method: "notifications/initialized",
            session: "conversation-session",
          },
          {
            socket: "conversation",
            method: "tools/call",
            session: "conversation-session",
          },
        ],
      });
      clock = 101;
      await sessions.sweep();
      const idle = await router.route(mcpRequest(method, false, headers));
      await idle.text();

      expect({
        status: idle.status,
        starts,
        destinations: destinations.slice(6),
      }).toStrictEqual({
        status: StatusCodes.NOT_FOUND,
        starts: [runtimeIdentity(user, conversation)],
        destinations: [],
      });
    } finally {
      await sessions.shutdown();
    }
  },
);

it.each(["http-error", "rpc-error", "invalid-json"])(
  "does not execute a tool when lazy initialization returns %s",
  async (failure) => {
    const router = new McpRouter(options);
    const initial = await router.route(mcpRequest("initialize"));
    await initial.text();
    const headers = {
      "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
    };
    const methods: string[] = [];
    options.forward = async (_guest, _server, request) => {
      const rpc = z.object({ method: z.string() }).parse(await request.json());
      methods.push(rpc.method);

      if (failure === "http-error") {
        return new Response(null, { status: StatusCodes.SERVICE_UNAVAILABLE });
      }

      if (failure === "invalid-json") {
        return new Response("invalid", {
          headers: { "content-type": "application/json" },
        });
      }

      return Response.json({
        jsonrpc: "2.0",
        id: 1,
        error: { code: -32603, message: "Initialization failed" },
      });
    };
    const response = await router.route(
      mcpRequest("tools/call", false, headers),
    );
    await response.text();
    const retry = await router.route(mcpRequest("tools/list", false, headers));
    await retry.text();

    expect({
      status: response.status,
      retry: retry.status,
      methods,
      released,
    }).toStrictEqual({
      status: StatusCodes.NOT_FOUND,
      retry: StatusCodes.NOT_FOUND,
      methods: ["initialize"],
      released: 2,
    });
  },
);

it("cancels catalogue discovery without acquiring a conversation lease", async () => {
  const reason = new DOMException("Discovery cancelled", "AbortError");
  const controller = new AbortController();
  let signal: AbortSignal | undefined;
  let acquired = false;
  options.catalogue = async (requestedSignal) => {
    signal = requestedSignal;
    controller.abort(reason);
    requestedSignal?.throwIfAborted();

    return await lease();
  };
  options.sessions.acquire = async () => {
    acquired = true;

    return await lease();
  };
  const request = new Request(mcpRequest("initialize"), {
    signal: controller.signal,
  });

  await expect(new McpRouter(options).route(request)).rejects.toBe(reason);
  expect({ signal, acquired, forwarded, released }).toStrictEqual({
    signal: request.signal,
    acquired: false,
    forwarded: [],
    released: 0,
  });
});

it.each(["cancel", "read-error"])(
  "releases discovery leases when the response body ends through %s",
  async (ending) => {
    const router = new McpRouter(options);
    const initial = await router.route(mcpRequest("initialize"));
    await initial.text();
    const headers = {
      "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
    };
    const failure = new Error("The guest response stream failed");
    options.forward = async () =>
      new Response(
        new ReadableStream({
          start(controller) {
            if (ending === "read-error") {
              controller.error(failure);
            }
          },
        }),
      );
    const response = await router.route(
      mcpRequest("tools/list", false, headers),
    );

    const result = await Promise.allSettled([
      ending === "cancel" ? response.body?.cancel() : response.text(),
    ]);

    expect({ released, result }).toStrictEqual({
      released: 2,
      result: [
        ending === "cancel"
          ? { status: "fulfilled", value: undefined }
          : { status: "rejected", reason: failure },
      ],
    });
  },
);
