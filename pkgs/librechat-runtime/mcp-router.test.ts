import { StatusCodes } from "http-status-codes";
import { beforeEach, expect, it } from "vitest";
import { McpRouter, type McpRouterOptions } from "./mcp-router.ts";
import type { Guest, SessionLease } from "./sessions.ts";

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
    { jsonrpc: "2.0", id: 1, result: {} },
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
    sessions: { acquire: lease },
    catalogue: lease,
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

  await (await router.route(mcpRequest("initialize"))).text();

  boot = "second-boot";

  const response = await router.route(
    mcpRequest("tools/call", false, { "mcp-session-id": "backend-session" }),
  );

  expect({
    status: response.status,
    forwards: forwarded.length,
    released,
  }).toStrictEqual({ status: StatusCodes.NOT_FOUND, forwards: 1, released: 2 });
});

it("rejects session reuse by another conversation", async () => {
  const router = new McpRouter(options);

  await (await router.route(mcpRequest("initialize"))).text();

  const response = await router.route(
    mcpRequest("tools/call", false, {
      "mcp-session-id": "backend-session",
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

  await (await router.route(mcpRequest("initialize"))).text();

  const original = mcpRequest("initialize", false, {
    "mcp-session-id": "backend-session",
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
