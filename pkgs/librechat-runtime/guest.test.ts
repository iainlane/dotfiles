import { StatusCodes } from "http-status-codes";
import { beforeEach, expect, it } from "vitest";
import { RequestBodyLimitError } from "./http-server.ts";
import {
  GuestGateway,
  NodeGuestOperations,
  type GuestOperations,
} from "./guest.ts";

type GuestBinding = Parameters<GuestOperations["bind"]>[0];

class UnexpectedGuestProcessError extends Error {
  constructor() {
    super("Forwarding a request must not start or execute a process");

    this.name = "UnexpectedGuestProcessError";
  }
}

let gateway: GuestGateway;

let operations: GuestOperations;

let events: string[];

const binding = {
  runtimeId: `rt_${"a".repeat(40)}`,
  caCertificate: "c".repeat(64),
  archiveToken: "a".repeat(32),
  executionPublicKey: "e".repeat(32),
};

beforeEach(() => {
  events = [];

  operations = {
    bind: async () => {
      events.push("bind");
    },
    resume: async () => {
      events.push("resume");
    },
    quiesce: async () => {
      events.push("quiesce");
    },
    shutdown: async () => {
      events.push("shutdown");
    },
    forward: async (_request, target, path) => {
      events.push(`${target}:${path}`);

      return new Response("forwarded");
    },
  };

  gateway = new GuestGateway(operations);
});

async function bind(): Promise<void> {
  await gateway.route(
    new Request("http://guest/control/bind", {
      method: "POST",
      body: JSON.stringify(binding),
    }),
  );
}

function bindingRequest(value: GuestBinding): Request {
  return new Request("http://guest/control/bind", {
    method: "POST",
    body: JSON.stringify(value),
  });
}

class FixtureBindingError extends Error {
  constructor() {
    super("The fixture binding could not initialise");

    this.name = "FixtureBindingError";
  }
}

it.each(["", "{"])("rejects malformed binding JSON: %j", async (body) => {
  const response = await gateway.route(
    new Request("http://guest/control/bind", {
      method: "POST",
      body,
    }),
  );

  const error: unknown = await response.json();

  expect({ status: response.status, error, events }).toStrictEqual({
    status: StatusCodes.BAD_REQUEST,
    error: {
      error: "GuestBindingFormatError",
      message: "The guest runtime binding is invalid",
    },
    events: [],
  });
});

it("preserves binding body transport and limit errors", async () => {
  const error = new RequestBodyLimitError();
  const init: RequestInit & { duplex: "half" } = {
    method: "POST",
    duplex: "half",
    body: new ReadableStream({
      start(controller) {
        controller.error(error);
      },
    }),
  };

  await expect(
    gateway.route(new Request("http://guest/control/bind", init)),
  ).rejects.toBe(error);

  expect(events).toStrictEqual([]);
});

it.each([
  { ...binding, runtimeId: `rt_${"b".repeat(40)}` },
  { ...binding, executionPublicKey: "f".repeat(32) },
])(
  "rejects a conflicting binding during initialisation: %j",
  async (conflict) => {
    const entered = Promise.withResolvers<void>();
    const secondEntered = Promise.withResolvers<void>();
    const finish = Promise.withResolvers<void>();
    const bindings: GuestBinding[] = [];

    operations.bind = async (value) => {
      bindings.push(value);
      entered.resolve();

      if (bindings.length === 2) {
        secondEntered.resolve();
      }

      await finish.promise;
    };

    const first = gateway.route(bindingRequest(binding));

    await entered.promise;

    const second = gateway.route(bindingRequest(conflict));

    await Promise.race([second, secondEntered.promise]);

    finish.resolve();

    const responses = await Promise.all([first, second]);
    const health = await gateway.route(new Request("http://guest/health"));
    const state: unknown = await health.json();

    expect({
      statuses: responses.map((response) => response.status),
      bindings,
      state,
    }).toStrictEqual({
      statuses: [StatusCodes.OK, StatusCodes.CONFLICT],
      bindings: [binding],
      state: { runtimeId: binding.runtimeId },
    });
  },
);

it("shares initialisation between identical concurrent bindings", async () => {
  const entered = Promise.withResolvers<void>();
  const finish = Promise.withResolvers<void>();

  operations.bind = async () => {
    events.push("bind");
    entered.resolve();

    await finish.promise;
  };

  const first = gateway.route(bindingRequest(binding));
  const second = gateway.route(bindingRequest(binding));

  await entered.promise;

  const health = await gateway.route(new Request("http://guest/health"));
  const initialState: unknown = await health.json();

  finish.resolve();

  const responses = await Promise.all([first, second]);

  expect({
    statuses: responses.map((response) => response.status),
    initialState,
    events,
  }).toStrictEqual({
    statuses: [StatusCodes.OK, StatusCodes.OK],
    initialState: { runtimeId: null },
    events: ["bind"],
  });
});

it("reuses an identical completed binding without reinitialising it", async () => {
  await bind();
  await bind();

  expect(events).toStrictEqual(["bind"]);
});

it("allows another binding after initialisation fails", async () => {
  const failure = new FixtureBindingError();

  operations.bind = async () => {
    throw failure;
  };

  await expect(gateway.route(bindingRequest(binding))).rejects.toBe(failure);

  operations.bind = async () => {
    events.push("bind");
  };

  const response = await gateway.route(
    bindingRequest({ ...binding, runtimeId: `rt_${"b".repeat(40)}` }),
  );

  expect({ status: response.status, events }).toStrictEqual({
    status: StatusCodes.OK,
    events: ["bind"],
  });
});

it.each([
  ["/runner/api/v2/execute", "GET"],
  ["/runner/api/v2/session/checkpoint", "DELETE"],
  ["/runner/api/v2/session/restore", "GET"],
])("rejects unsupported runner method %s %s", async (path, method) => {
  await bind();

  events = [];

  const response = await gateway.route(
    new Request(`http://guest${path}`, {
      method,
      headers: { "x-runtime-session-id": binding.runtimeId },
    }),
  );

  expect({ status: response.status, events }).toStrictEqual({
    status: StatusCodes.METHOD_NOT_ALLOWED,
    events: [],
  });
});

it("rejects a different runtime without forwarding the request", async () => {
  await bind();

  events = [];

  const response = await gateway.route(
    new Request("http://guest/runner/api/v2/execute", {
      method: "POST",
      headers: { "x-runtime-session-id": `rt_${"b".repeat(40)}` },
    }),
  );

  expect({ status: response.status, events }).toStrictEqual({
    status: StatusCodes.FORBIDDEN,
    events: [],
  });
});

it("quiesces MCP before reporting success", async () => {
  await bind();

  events = [];

  const response = await gateway.route(
    new Request("http://guest/control/quiesce", { method: "POST" }),
  );

  expect({ status: response.status, events }).toStrictEqual({
    status: StatusCodes.OK,
    events: ["quiesce"],
  });
});

it("forwards application headers and body without connection-specific headers", async () => {
  const requests: Request[] = [];

  const guestOperations = new NodeGuestOperations(
    {
      runner: "/unused",
      runnerEnvironment: {},
      mcpProxy: "/unused",
      mcpEnvironment: {},
      mcpConfiguration: "/unused",
      caBundle: "/unused",
      systemdRun: "/unused",
      systemctl: "/unused",
      workspace: {
        uid: 200000,
        gid: 200000,
        mkdir: "/unused",
        certutil: "/unused",
      },
    },
    {
      run: async () => {
        throw new UnexpectedGuestProcessError();
      },
      start: async () => {
        throw new UnexpectedGuestProcessError();
      },
    },
    async (input, init) => {
      requests.push(new Request(input, init));

      return new Response("forwarded");
    },
  );

  const response = await guestOperations.forward(
    new Request("http://guest/runner/api/v2/execute", {
      method: "POST",
      headers: {
        authorization: "scoped-credential",
        "content-type": "application/json",
        host: "guest",
        connection: "keep-alive, x-hop, ",
        "keep-alive": "timeout=5",
        "transfer-encoding": "chunked",
        "x-hop": "private",
        "x-runtime-session-id": binding.runtimeId,
      },
      body: "{}",
    }),
    "runner",
    "/api/v2/execute",
  );

  expect({
    response: await response.text(),
    requests: await Promise.all(
      requests.map(async (request) => ({
        url: request.url,
        method: request.method,
        headers: Object.fromEntries(request.headers),
        body: await request.text(),
      })),
    ),
  }).toStrictEqual({
    response: "forwarded",
    requests: [
      {
        url: "http://127.0.0.1:2000/api/v2/execute",
        method: "POST",
        headers: {
          authorization: "scoped-credential",
          "content-type": "application/json",
          "x-runtime-session-id": binding.runtimeId,
        },
        body: "{}",
      },
    ],
  });
});
