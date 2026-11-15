import { runtimeIdentity } from "#runtime/platform/identity";
import { configureLocalMcp } from "#runtime/host/config";
import { z } from "zod";
import { StatusCodes } from "http-status-codes";
import { beforeEach, expect, it } from "vitest";
import { McpRouter, type McpRouterOptions } from "#runtime/mcp/mcp-router";
import {
  SessionManager,
  type Guest,
  type GuestBackend,
  type Session,
  type SessionLease,
} from "#runtime/sessions/sessions";

const token = "a".repeat(64);

const user = "0123456789abcdef01234567";

const conversation = "ea277865-9bbd-45ec-9cd2-234cf9dc9169";

const conversationSession: Session = {
  runtimeId: "test",
  conversationId: conversation,
  userId: user,
  generation: 1,
  lastUsed: 0,
  checkpoint: false,
  expired: false,
  resetReason: "",
  quarantine: null,
};

class GuestAlreadyRunningError extends Error {
  constructor() {
    super("The fixture guest is already running");

    this.name = "GuestAlreadyRunningError";
  }
}

function initializeResponse(): Response {
  return Response.json(
    { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-03-26" } },
    { headers: { "mcp-session-id": "backend-session" } },
  );
}

class FixtureGuests {
  bootId = "first-boot";
  respond: (request: Request) => Promise<Response> = async () =>
    initializeResponse();
  whileStarting: () => void = () => {};
  private readonly running = new Set<string>();
  private readonly leases = new Set<SessionLease>();
  private readonly forwarded: {
    socket: string;
    server: string;
    headers: Record<string, string>;
    body: string;
  }[] = [];

  restart(bootId: string): void {
    this.bootId = bootId;
  }

  async lease(socket: string, signal?: AbortSignal): Promise<SessionLease> {
    if (!this.running.has(socket)) {
      this.whileStarting();
      signal?.throwIfAborted();
      this.running.add(socket);
    }

    const lease: SessionLease = {
      session: conversationSession,
      guest: { socket, bootId: this.bootId },
      release: async () => {
        this.leases.delete(lease);
      },
    };

    this.leases.add(lease);

    return lease;
  }

  async leaseRunning(socket: string): Promise<SessionLease | null> {
    return this.running.has(socket) ? await this.lease(socket) : null;
  }

  async forward(
    guest: Guest,
    server: string,
    request: Request,
  ): Promise<Response> {
    this.forwarded.push({
      socket: guest.socket,
      server,
      headers: Object.fromEntries(request.headers),
      body: await request.clone().text(),
    });

    return await this.respond(request);
  }

  options(): McpRouterOptions {
    return {
      token,
      userId: user,
      servers: new Set(["git"]),
      sessions: {
        register: async () => conversationSession,
        acquire: async (_id, signal) =>
          await this.lease("conversation", signal),
        acquireRunning: async () => await this.leaseRunning("conversation"),
      },
      catalogue: async (signal) => await this.lease("catalogue", signal),
      catalogueRunning: async () => await this.leaseRunning("catalogue"),
      forward: async (guest, server, request) =>
        await this.forward(guest, server, request),
    };
  }

  state() {
    return {
      running: [...this.running],
      leases: [...this.leases].map((lease) => lease.guest.socket),
      forwarded: this.forwarded,
    };
  }
}

class FixtureBackend implements GuestBackend {
  readonly running = new Set<string>();

  async start(session: Session): Promise<Guest> {
    if (this.running.has(session.runtimeId)) {
      throw new GuestAlreadyRunningError();
    }

    this.running.add(session.runtimeId);

    return { socket: "conversation", bootId: "conversation-boot" };
  }

  async checkpoint(): Promise<void> {}

  async stop(session: Session): Promise<void> {
    this.running.delete(session.runtimeId);
  }

  async remove(): Promise<void> {}
}

function sessionManager(now: () => number = () => 0) {
  const records = new Map<string, Session>();
  const backend = new FixtureBackend();
  const sessions = new SessionManager({
    userId: user,
    idleMs: 100,
    retentionMs: 1000,
    now,
    store: {
      load: async (id) => records.get(id),
      save: async (session) => {
        records.set(session.runtimeId, structuredClone(session));
      },
      list: async () => [...records.keys()],
    },
    backend,
  });

  return { sessions, records, backend };
}

let guests: FixtureGuests;

beforeEach(() => {
  guests = new FixtureGuests();
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

function rpc(method: string): string {
  return JSON.stringify({ jsonrpc: "2.0", id: 1, method });
}

it("initialises tools before the conversation hook has registered a workspace", async () => {
  const { sessions, records } = sessionManager();

  try {
    const response = await new McpRouter({
      ...guests.options(),
      sessions,
    }).route(mcpRequest("initialize"));
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
  const { sessions, records, backend } = sessionManager();
  const request = new Request(mcpRequest("initialize"), {
    signal: AbortSignal.abort(
      new DOMException("MCP request cancelled", "AbortError"),
    ),
  });

  try {
    await expect(
      new McpRouter({ ...guests.options(), sessions }).route(request),
    ).rejects.toStrictEqual(
      new DOMException("MCP request cancelled", "AbortError"),
    );

    expect({
      records: [...records],
      vms: [...backend.running],
      guests: guests.state(),
    }).toStrictEqual({
      records: [],
      vms: [],
      guests: { running: [], leases: [], forwarded: [] },
    });
  } finally {
    await sessions.shutdown();
  }
});

it.each(["tools/call", "resources/read", "prompts/get"])(
  "rejects %s on catalogue connections",
  async (method) => {
    const response = await new McpRouter(guests.options()).route(
      mcpRequest(method, true),
    );

    expect({
      status: response.status,
      guests: guests.state(),
    }).toStrictEqual({
      status: StatusCodes.FORBIDDEN,
      guests: { running: [], leases: [], forwarded: [] },
    });
  },
);

it("authenticates before acquiring a VM", async () => {
  const response = await new McpRouter(guests.options()).route(
    mcpRequest("initialize", false, { authorization: "Bearer wrong" }),
  );

  expect({ status: response.status, guests: guests.state() }).toStrictEqual({
    status: StatusCodes.UNAUTHORIZED,
    guests: { running: [], leases: [], forwarded: [] },
  });
});

it("strips host credentials and routing headers before forwarding", async () => {
  const response = await new McpRouter(guests.options()).route(
    mcpRequest("initialize"),
  );

  await response.text();

  expect(guests.state()).toStrictEqual({
    running: ["catalogue"],
    leases: [],
    forwarded: [
      {
        socket: "catalogue",
        server: "git",
        headers: { "content-type": "application/json" },
        body: rpc("initialize"),
      },
    ],
  });
});

it("rejects stale sessions after a VM restart without replaying a call", async () => {
  const router = new McpRouter(guests.options());

  const initial = await router.route(mcpRequest("initialize"));
  await initial.text();
  const headers = {
    "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
  };
  await (await router.route(mcpRequest("tools/call", false, headers))).text();

  guests.restart("second-boot");

  const response = await router.route(mcpRequest("tools/call", false, headers));

  const { forwarded, ...state } = guests.state();

  expect({
    status: response.status,
    state,
    forwarded: forwarded.map(({ socket, body }) => ({ socket, body })),
  }).toStrictEqual({
    status: StatusCodes.NOT_FOUND,
    state: { running: ["catalogue", "conversation"], leases: [] },
    forwarded: [
      { socket: "catalogue", body: rpc("initialize") },
      { socket: "conversation", body: rpc("initialize") },
      {
        socket: "conversation",
        body: JSON.stringify({
          jsonrpc: "2.0",
          method: "notifications/initialized",
        }),
      },
      { socket: "conversation", body: rpc("tools/call") },
    ],
  });
});

it("rejects session reuse by another conversation", async () => {
  const router = new McpRouter(guests.options());

  const initial = await router.route(mcpRequest("initialize"));
  await initial.text();

  const response = await router.route(
    mcpRequest("tools/call", false, {
      "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
      "x-librechat-conversation-id": "dbd5bc71-a5a0-4363-8672-e84c9ccad80f",
    }),
  );

  expect({
    status: response.status,
    forwarded: guests.state().forwarded.map(({ socket, body }) => ({
      socket,
      body,
    })),
  }).toStrictEqual({
    status: StatusCodes.NOT_FOUND,
    forwarded: [{ socket: "catalogue", body: rpc("initialize") }],
  });
});

it("rejects catalogue event streams before acquiring a VM", async () => {
  const request = new Request("http://controller/mcp/git", {
    headers: { authorization: `Bearer ${token}`, accept: "text/event-stream" },
  });

  const response = await new McpRouter(guests.options()).route(request);

  expect({ status: response.status, guests: guests.state() }).toStrictEqual({
    status: StatusCodes.METHOD_NOT_ALLOWED,
    guests: { running: [], leases: [], forwarded: [] },
  });
});

it("forwards client replies to server requests within the bound conversation", async () => {
  const router = new McpRouter(guests.options());

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

  const { forwarded, leases } = guests.state();

  expect({
    status: response.status,
    reply: forwarded.at(-1)?.body,
    leases,
  }).toStrictEqual({
    status: StatusCodes.OK,
    reply: JSON.stringify(reply),
    leases: [],
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
    let clock = 0;
    const { sessions, backend } = sessionManager(() => clock);
    const destinations: {
      socket: string;
      method: string;
      session: string | null;
    }[] = [];
    const router = new McpRouter({
      ...guests.options(),
      sessions,
      catalogue: async () => ({
        ...(await guests.lease("catalogue")),
        guest: { socket: "catalogue", bootId: "catalogue-boot" },
      }),
      catalogueRunning: async () => ({
        ...(await guests.lease("catalogue")),
        guest: { socket: "catalogue", bootId: "catalogue-boot" },
      }),
      forward: async (guest, _server, request) => {
        const message = z
          .object({ method: z.string() })
          .parse(await request.json());
        destinations.push({
          socket: guest.socket,
          method: message.method,
          session: request.headers.get("mcp-session-id"),
        });
        return Response.json(
          { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-03-26" } },
          {
            headers:
              message.method === "initialize"
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
      expect({ vms: [...backend.running], destinations }).toStrictEqual({
        vms: [],
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
      expect({
        vms: [...backend.running],
        destinations: destinations.slice(3),
      }).toStrictEqual({
        vms: [runtimeIdentity(user, conversation)],
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
        vms: [...backend.running],
        destinations: destinations.slice(6),
      }).toStrictEqual({
        status: StatusCodes.NOT_FOUND,
        vms: [],
        destinations: [],
      });
    } finally {
      await sessions.shutdown();
    }
  },
);

it.each([
  {
    failure: "http-error",
    response: () =>
      new Response(null, { status: StatusCodes.SERVICE_UNAVAILABLE }),
  },
  {
    failure: "rpc-error",
    response: () =>
      Response.json({
        jsonrpc: "2.0",
        id: 1,
        error: { code: -32603, message: "Initialization failed" },
      }),
  },
  {
    failure: "invalid-json",
    response: () =>
      new Response("invalid", {
        headers: { "content-type": "application/json" },
      }),
  },
])(
  "does not execute a tool when lazy initialization returns $failure",
  async ({ response: failed }) => {
    const router = new McpRouter(guests.options());
    const initial = await router.route(mcpRequest("initialize"));
    await initial.text();
    const headers = {
      "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
    };
    guests.respond = async () => failed();
    const response = await router.route(
      mcpRequest("tools/call", false, headers),
    );
    await response.text();
    const retry = await router.route(mcpRequest("tools/list", false, headers));
    await retry.text();

    const { forwarded, leases } = guests.state();

    expect({
      status: response.status,
      retry: retry.status,
      forwarded: forwarded.map(({ socket, body }) => ({ socket, body })),
      leases,
    }).toStrictEqual({
      status: StatusCodes.NOT_FOUND,
      retry: StatusCodes.NOT_FOUND,
      forwarded: [
        { socket: "catalogue", body: rpc("initialize") },
        { socket: "conversation", body: rpc("initialize") },
      ],
      leases: [],
    });
  },
);

it("cancels catalogue discovery without acquiring a conversation lease", async () => {
  const controller = new AbortController();
  guests.whileStarting = () => {
    controller.abort(new DOMException("Discovery cancelled", "AbortError"));
  };
  const request = new Request(mcpRequest("initialize"), {
    signal: controller.signal,
  });

  await expect(
    new McpRouter(guests.options()).route(request),
  ).rejects.toStrictEqual(
    new DOMException("Discovery cancelled", "AbortError"),
  );

  expect(guests.state()).toStrictEqual({
    running: [],
    leases: [],
    forwarded: [],
  });
});

async function discoveryResponse(body: ReadableStream): Promise<Response> {
  const router = new McpRouter(guests.options());
  const initial = await router.route(mcpRequest("initialize"));
  await initial.text();
  const headers = {
    "mcp-session-id": initial.headers.get("mcp-session-id") ?? "",
  };
  guests.respond = async () => new Response(body);

  return await router.route(mcpRequest("tools/list", false, headers));
}

it("releases discovery leases when the client cancels the response body", async () => {
  const response = await discoveryResponse(new ReadableStream());

  await response.body?.cancel();

  expect(guests.state().leases).toStrictEqual([]);
});

it("releases discovery leases when the response body fails", async () => {
  const response = await discoveryResponse(
    new ReadableStream({
      start(controller) {
        controller.error(new Error("The guest response stream failed"));
      },
    }),
  );

  await expect(response.text()).rejects.toStrictEqual(
    new Error("The guest response stream failed"),
  );

  expect(guests.state().leases).toStrictEqual([]);
});
