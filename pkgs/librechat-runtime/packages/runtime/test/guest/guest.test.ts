import { StatusCodes } from "http-status-codes";
import { beforeEach, expect, it } from "vitest";
import { RequestBodyLimitError } from "#runtime/http/http-server";
import {
  GuestGateway,
  NodeGuestOperations,
  type GuestOperations,
} from "#runtime/guest/guest";

type GuestBinding = Parameters<GuestOperations["bind"]>[0];

class UnexpectedGuestProcessError extends Error {
  constructor() {
    super("Forwarding a request must not start or execute a process");

    this.name = "UnexpectedGuestProcessError";
  }
}

class GuestAlreadyBoundError extends Error {
  constructor() {
    super("The fixture guest accepts one binding");

    this.name = "GuestAlreadyBoundError";
  }
}

class FixtureBindingError extends Error {
  constructor() {
    super("The fixture binding could not initialise");

    this.name = "FixtureBindingError";
  }
}

class FixtureGuest implements GuestOperations {
  failure: Error | undefined;
  private bound: GuestBinding | undefined;
  private initialising = false;
  private mcp: "stopped" | "running" | "quiesced" = "stopped";
  private clock: number | undefined;
  private initialisation: Promise<void> = Promise.resolve();
  private readonly started = Promise.withResolvers<void>();

  get initialisationStarted(): Promise<void> {
    return this.started.promise;
  }

  holdInitialisation(): () => void {
    const gate = Promise.withResolvers<void>();

    this.initialisation = gate.promise;

    return () => gate.resolve();
  }

  async bind(binding: GuestBinding): Promise<void> {
    if (this.initialising || this.bound !== undefined) {
      throw new GuestAlreadyBoundError();
    }

    this.initialising = true;
    this.started.resolve();

    try {
      await this.initialisation;

      if (this.failure !== undefined) {
        throw this.failure;
      }

      this.bound = binding;
    } finally {
      this.initialising = false;
    }
  }

  async resume(time?: number): Promise<void> {
    this.clock = time ?? this.clock;
    this.mcp = "running";
  }

  async quiesce(): Promise<void> {
    this.mcp = "quiesced";
  }

  async shutdown(): Promise<void> {
    this.mcp = "stopped";
  }

  async forward(
    _request: Request,
    target: "runner" | "mcp",
    path: string,
  ): Promise<Response> {
    return Response.json({ target, path });
  }

  state() {
    return { bound: this.bound, mcp: this.mcp, clock: this.clock };
  }
}

let guest: FixtureGuest;

let gateway: GuestGateway;

const binding = {
  runtimeId: `rt_${"a".repeat(40)}`,
  caCertificate: "c".repeat(64),
  archiveToken: "a".repeat(32),
  executionPublicKey: "e".repeat(32),
};

beforeEach(() => {
  guest = new FixtureGuest();

  gateway = new GuestGateway(guest);
});

function bindingRequest(value: GuestBinding): Request {
  return new Request("http://guest/control/bind", {
    method: "POST",
    body: JSON.stringify(value),
  });
}

async function bind(): Promise<Response> {
  return await gateway.route(bindingRequest(binding));
}

async function health(): Promise<unknown> {
  const response = await gateway.route(new Request("http://guest/health"));

  return await response.json();
}

it.each(["", "{"])("rejects malformed binding JSON: %j", async (body) => {
  const response = await gateway.route(
    new Request("http://guest/control/bind", {
      method: "POST",
      body,
    }),
  );

  const error: unknown = await response.json();

  expect({
    status: response.status,
    error,
    guest: guest.state(),
  }).toStrictEqual({
    status: StatusCodes.BAD_REQUEST,
    error: {
      error: "GuestBindingFormatError",
      message: "The guest runtime binding is invalid",
    },
    guest: { bound: undefined, mcp: "stopped", clock: undefined },
  });
});

it("preserves binding body transport and limit errors", async () => {
  const init: RequestInit & { duplex: "half" } = {
    method: "POST",
    duplex: "half",
    body: new ReadableStream({
      start(controller) {
        controller.error(new RequestBodyLimitError());
      },
    }),
  };

  await expect(
    gateway.route(new Request("http://guest/control/bind", init)),
  ).rejects.toStrictEqual(new RequestBodyLimitError());

  expect(guest.state()).toStrictEqual({
    bound: undefined,
    mcp: "stopped",
    clock: undefined,
  });
});

it.each([
  { ...binding, runtimeId: `rt_${"b".repeat(40)}` },
  { ...binding, executionPublicKey: "f".repeat(32) },
])(
  "rejects a conflicting binding during initialisation: %j",
  async (conflict) => {
    const finish = guest.holdInitialisation();

    const first = gateway.route(bindingRequest(binding));

    await guest.initialisationStarted;

    const second = await gateway.route(bindingRequest(conflict));

    finish();

    const responses = [await first, second];

    expect({
      statuses: responses.map((response) => response.status),
      state: await health(),
      bound: guest.state().bound,
    }).toStrictEqual({
      statuses: [StatusCodes.OK, StatusCodes.CONFLICT],
      state: { runtimeId: binding.runtimeId, resumeClock: true },
      bound: binding,
    });
  },
);

it("shares initialisation between identical concurrent bindings", async () => {
  const finish = guest.holdInitialisation();

  const first = gateway.route(bindingRequest(binding));
  const second = gateway.route(bindingRequest(binding));

  await guest.initialisationStarted;

  const initialState = await health();

  finish();

  const responses = await Promise.all([first, second]);

  expect({
    statuses: responses.map((response) => response.status),
    initialState,
    state: await health(),
  }).toStrictEqual({
    statuses: [StatusCodes.OK, StatusCodes.OK],
    initialState: { runtimeId: null, resumeClock: true },
    state: { runtimeId: binding.runtimeId, resumeClock: true },
  });
});

it("reuses an identical completed binding without reinitialising it", async () => {
  await bind();

  const response = await bind();

  expect({
    status: response.status,
    bound: guest.state().bound,
  }).toStrictEqual({ status: StatusCodes.OK, bound: binding });
});

it("reports a failed shared initialisation to every concurrent binding", async () => {
  guest.failure = new FixtureBindingError();

  const finish = guest.holdInitialisation();

  const first = gateway.route(bindingRequest(binding));
  const second = gateway.route(bindingRequest(binding));

  await guest.initialisationStarted;

  finish();

  const outcomes = await Promise.allSettled([first, second]);

  expect({ outcomes, state: await health() }).toStrictEqual({
    outcomes: [
      { status: "rejected", reason: new FixtureBindingError() },
      { status: "rejected", reason: new FixtureBindingError() },
    ],
    state: { runtimeId: null, resumeClock: true },
  });
});

it("allows another binding after initialisation fails", async () => {
  guest.failure = new FixtureBindingError();

  await expect(gateway.route(bindingRequest(binding))).rejects.toStrictEqual(
    new FixtureBindingError(),
  );

  guest.failure = undefined;

  const replacement = { ...binding, runtimeId: `rt_${"b".repeat(40)}` };

  const response = await gateway.route(bindingRequest(replacement));

  expect({
    status: response.status,
    bound: guest.state().bound,
  }).toStrictEqual({ status: StatusCodes.OK, bound: replacement });
});

it.each([
  ["/runner/api/v2/execute", "GET"],
  ["/runner/api/v2/session/checkpoint", "DELETE"],
  ["/runner/api/v2/session/restore", "GET"],
])("rejects unsupported runner method %s %s", async (path, method) => {
  await bind();

  const response = await gateway.route(
    new Request(`http://guest${path}`, {
      method,
      headers: { "x-runtime-session-id": binding.runtimeId },
    }),
  );

  const body: unknown = await response.json();

  expect({ status: response.status, body }).toStrictEqual({
    status: StatusCodes.METHOD_NOT_ALLOWED,
    body: {
      error: "GuestHttpMethodError",
      message: "The guest route does not accept this HTTP method",
    },
  });
});

it("rejects a different runtime without forwarding the request", async () => {
  await bind();

  const response = await gateway.route(
    new Request("http://guest/runner/api/v2/execute", {
      method: "POST",
      headers: { "x-runtime-session-id": `rt_${"b".repeat(40)}` },
    }),
  );

  const body: unknown = await response.json();

  expect({ status: response.status, body }).toStrictEqual({
    status: StatusCodes.FORBIDDEN,
    body: {
      error: "GuestRuntimeMismatchError",
      message: "The requested runtime differs from the guest runtime",
    },
  });
});

it("quiesces MCP before reporting success", async () => {
  await bind();

  const response = await gateway.route(
    new Request("http://guest/control/quiesce", { method: "POST" }),
  );

  expect({ status: response.status, guest: guest.state() }).toStrictEqual({
    status: StatusCodes.OK,
    guest: { bound: binding, mcp: "quiesced", clock: undefined },
  });
});

it("forwards application headers and body without connection-specific headers", async () => {
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
      date: "/unused",
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
    {
      fetch: async (input, init) => {
        const request = new Request(input, init);

        return Response.json({
          url: request.url,
          method: request.method,
          headers: Object.fromEntries(request.headers),
          body: await request.text(),
        });
      },
      onError: () => {
        throw new UnexpectedGuestProcessError();
      },
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

  const body: unknown = await response.json();

  expect(body).toStrictEqual({
    url: "http://127.0.0.1:2000/api/v2/execute",
    method: "POST",
    headers: {
      authorization: "scoped-credential",
      "content-type": "application/json",
      "x-runtime-session-id": binding.runtimeId,
    },
    body: "{}",
  });
});

it("passes the host clock to the resume operation", async () => {
  await bind();

  const response = await gateway.route(
    new Request("http://guest/control/resume", {
      method: "POST",
      headers: { "x-librechat-resume-time": "1793309000000" },
    }),
  );

  expect({ status: response.status, guest: guest.state() }).toStrictEqual({
    status: StatusCodes.OK,
    guest: {
      bound: binding,
      mcp: "running",
      clock: 1793309000000,
    },
  });
});

it.each(["invalid", "-1", "Infinity", ""])(
  "rejects an invalid resume time %j",
  async (time) => {
    await bind();

    const response = await gateway.route(
      new Request("http://guest/control/resume", {
        method: "POST",
        headers: { "x-librechat-resume-time": time },
      }),
    );

    expect({ status: response.status, guest: guest.state() }).toStrictEqual({
      status: StatusCodes.BAD_REQUEST,
      guest: { bound: binding, mcp: "stopped", clock: undefined },
    });
  },
);
