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

const rpcMessage = z.looseObject({
  id: z.union([z.string(), z.number()]).optional(),
  method: z.string().optional(),
});

class FixtureGuests {
  bootId = "first-boot";
  readonly responses = new Map<string, () => Response>();
  whileStarting: () => void = () => {};
  private readonly running = new Set<string>();
  private readonly leases = new Set<SessionLease>();
  private readonly mcpSessions = new Map<string, "initialising" | "ready">();

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
    const received = rpcMessage.parse(await request.json());
    const fixed =
      received.method === undefined
        ? undefined
        : this.responses.get(received.method);

    if (fixed !== undefined) {
      return fixed();
    }

    const origin = {
      socket: guest.socket,
      server,
      headers: Object.fromEntries(request.headers),
    };
    const current = `${guest.socket}@${guest.bootId}`;

    if (received.method === "initialize") {
      this.mcpSessions.set(current, "initialising");

      return Response.json(
        {
          jsonrpc: "2.0",
          id: received.id,
          result: { protocolVersion: "2025-03-26", ...origin },
        },
        { headers: { "mcp-session-id": current } },
      );
    }

    const session = request.headers.get("mcp-session-id");
    const state = session === current ? this.mcpSessions.get(current) : null;

    if (state === undefined || state === null) {
      return Response.json(
        { jsonrpc: "2.0", error: { code: -32001, message: "Unknown session" } },
        { status: StatusCodes.NOT_FOUND },
      );
    }

    if (received.method === "notifications/initialized") {
      this.mcpSessions.set(current, "ready");

      return new Response(null, { status: StatusCodes.ACCEPTED });
    }

    if (state !== "ready") {
      return Response.json(
        { jsonrpc: "2.0", error: { code: -32600, message: "Not initialised" } },
        { status: StatusCodes.BAD_REQUEST },
      );
    }

    return Response.json({ ...origin, message: received });
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

async function settled(
  response: Response,
): Promise<{ status: number; body: unknown }> {
  const text = await response.text();
  const body: unknown = text === "" ? null : JSON.parse(text);

  return { status: response.status, body };
}

function rpc(method: string) {
  return { jsonrpc: "2.0", id: 1, method };
}

function echo(socket: string, session: string, message: unknown) {
  return {
    socket,
    server: "git",
    headers: { "content-type": "application/json", "mcp-session-id": session },
    message,
  };
}

const sessionMissing = {
  status: StatusCodes.NOT_FOUND,
  body: {
    error: "McpSessionError",
    message: "MCP session is unknown or belongs to an earlier VM boot",
  },
};

async function connect(router: McpRouter): Promise<Record<string, string>> {
  const initial = await router.route(mcpRequest("initialize"));
  await initial.text();

  return { "mcp-session-id": initial.headers.get("mcp-session-id") ?? "" };
}

it("initialises tools before the conversation hook has registered a workspace", async () => {
  const { sessions, records } = sessionManager();

  try {
    const response = await new McpRouter({
      ...guests.options(),
      sessions,
    }).route(mcpRequest("initialize"));

    expect({
      response: await settled(response),
      workspaces: [...records.values()].map(({ userId, conversationId }) => ({
        userId,
        conversationId,
      })),
    }).toStrictEqual({
      response: {
        status: StatusCodes.OK,
        body: {
          jsonrpc: "2.0",
          id: 1,
          result: {
            protocolVersion: "2025-03-26",
            socket: "catalogue",
            server: "git",
            headers: { "content-type": "application/json" },
          },
        },
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
      guests: { running: [], leases: [] },
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
      response: await settled(response),
      guests: guests.state(),
    }).toStrictEqual({
      response: {
        status: StatusCodes.FORBIDDEN,
        body: {
          error: "McpCatalogueExecutionError",
          message:
            "Catalogue connections cannot execute tools or read workspace data",
        },
      },
      guests: { running: [], leases: [] },
    });
  },
);

it("authenticates before acquiring a VM", async () => {
  const response = await new McpRouter(guests.options()).route(
    mcpRequest("initialize", false, { authorization: "Bearer wrong" }),
  );

  expect({
    response: await settled(response),
    guests: guests.state(),
  }).toStrictEqual({
    response: {
      status: StatusCodes.UNAUTHORIZED,
      body: {
        error: "McpAuthenticationError",
        message: "Unauthorised MCP request",
      },
    },
    guests: { running: [], leases: [] },
  });
});

it("strips host credentials and routing headers before forwarding", async () => {
  const response = await new McpRouter(guests.options()).route(
    mcpRequest("initialize"),
  );

  expect({
    response: await settled(response),
    guests: guests.state(),
  }).toStrictEqual({
    response: {
      status: StatusCodes.OK,
      body: {
        jsonrpc: "2.0",
        id: 1,
        result: {
          protocolVersion: "2025-03-26",
          socket: "catalogue",
          server: "git",
          headers: { "content-type": "application/json" },
        },
      },
    },
    guests: { running: ["catalogue"], leases: [] },
  });
});

it("rejects stale sessions after a VM restart without replaying a call", async () => {
  const router = new McpRouter(guests.options());
  const headers = await connect(router);

  const before = await settled(
    await router.route(mcpRequest("tools/call", false, headers)),
  );

  guests.restart("second-boot");

  const after = await settled(
    await router.route(mcpRequest("tools/call", false, headers)),
  );

  expect({ before, after, guests: guests.state() }).toStrictEqual({
    before: {
      status: StatusCodes.OK,
      body: echo("conversation", "conversation@first-boot", rpc("tools/call")),
    },
    after: sessionMissing,
    guests: { running: ["catalogue", "conversation"], leases: [] },
  });
});

it("rejects session reuse by another conversation", async () => {
  const router = new McpRouter(guests.options());
  const headers = await connect(router);

  const response = await router.route(
    mcpRequest("tools/call", false, {
      ...headers,
      "x-librechat-conversation-id": "dbd5bc71-a5a0-4363-8672-e84c9ccad80f",
    }),
  );

  expect({
    response: await settled(response),
    guests: guests.state(),
  }).toStrictEqual({
    response: sessionMissing,
    guests: { running: ["catalogue"], leases: [] },
  });
});

it("rejects catalogue event streams before acquiring a VM", async () => {
  const request = new Request("http://controller/mcp/git", {
    headers: { authorization: `Bearer ${token}`, accept: "text/event-stream" },
  });

  const response = await new McpRouter(guests.options()).route(request);

  expect({
    response: await settled(response),
    guests: guests.state(),
  }).toStrictEqual({
    response: {
      status: StatusCodes.METHOD_NOT_ALLOWED,
      body: {
        error: "McpHttpMethodError",
        message: "Unsupported MCP HTTP method",
      },
    },
    guests: { running: [], leases: [] },
  });
});

it("forwards client replies to server requests within the bound conversation", async () => {
  const router = new McpRouter(guests.options());
  const headers = await connect(router);

  await (
    await router.route(mcpRequest("notifications/initialized", false, headers))
  ).text();

  const original = mcpRequest("initialize", false, headers);

  const reply = { jsonrpc: "2.0", id: "roots", result: { roots: [] } };

  const response = await router.route(
    new Request(original.url, {
      method: "POST",
      headers: original.headers,
      body: JSON.stringify(reply),
    }),
  );

  expect({
    response: await settled(response),
    leases: guests.state().leases,
  }).toStrictEqual({
    response: {
      status: StatusCodes.OK,
      body: echo("catalogue", "catalogue@first-boot", reply),
    },
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
    const router = new McpRouter({ ...guests.options(), sessions });

    try {
      const headers = await connect(router);

      const initialized = await settled(
        await router.route(
          mcpRequest("notifications/initialized", false, headers),
        ),
      );
      const discovery = await settled(
        await router.route(mcpRequest("tools/list", false, headers)),
      );
      const discoveryVms = [...backend.running];

      const execution = await settled(
        await router.route(mcpRequest("tools/call", false, headers)),
      );
      const executionVms = [...backend.running];

      clock = 101;
      await sessions.sweep();

      const idle = await settled(
        await router.route(mcpRequest(method, false, headers)),
      );

      expect({
        initialized,
        discovery,
        discoveryVms,
        execution,
        executionVms,
        idle,
        idleVms: [...backend.running],
      }).toStrictEqual({
        initialized: { status: StatusCodes.ACCEPTED, body: null },
        discovery: {
          status: StatusCodes.OK,
          body: echo("catalogue", "catalogue@first-boot", rpc("tools/list")),
        },
        discoveryVms: [],
        execution: {
          status: StatusCodes.OK,
          body: echo(
            "conversation",
            "conversation@conversation-boot",
            rpc("tools/call"),
          ),
        },
        executionVms: [runtimeIdentity(user, conversation)],
        idle: sessionMissing,
        idleVms: [],
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
    const headers = await connect(router);

    guests.responses.set("initialize", failed);

    const response = await settled(
      await router.route(mcpRequest("tools/call", false, headers)),
    );
    const retry = await settled(
      await router.route(mcpRequest("tools/list", false, headers)),
    );

    expect({
      response,
      retry,
      leases: guests.state().leases,
    }).toStrictEqual({
      response: sessionMissing,
      retry: sessionMissing,
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

  expect(guests.state()).toStrictEqual({ running: [], leases: [] });
});

async function discoveryResponse(body: ReadableStream): Promise<Response> {
  const router = new McpRouter(guests.options());
  const headers = await connect(router);

  guests.responses.set("tools/list", () => new Response(body));

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
