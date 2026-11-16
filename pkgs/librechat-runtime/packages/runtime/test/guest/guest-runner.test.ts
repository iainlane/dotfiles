import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import { createConnection, Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { text } from "node:stream/consumers";
import { afterEach, beforeEach, expect, it } from "vitest";
import {
  GuestRunner,
  GuestRunnerConnectionError,
  GuestRunnerStartupError,
  GuestRunnerUnavailableError,
} from "#runtime/guest/guest-runner";

interface RunnerBehaviour {
  listensAt: number;
  healthyAt: number;
  crashOnRequest: boolean;
}

class FixtureRunner {
  time = 0;
  readonly socket: string;
  private readonly behaviour: RunnerBehaviour;
  private readonly server: Server;
  private listening = false;

  constructor(socket: string, behaviour: Partial<RunnerBehaviour>) {
    this.socket = socket;
    this.behaviour = {
      listensAt: 0,
      healthyAt: 0,
      crashOnRequest: false,
      ...behaviour,
    };
    this.server = createServer((request, response) => {
      void this.answer(request, response);
    });
  }

  private async answer(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    const body = await text(request);

    if (request.url === "/api/v2/health") {
      response.writeHead(this.time >= this.behaviour.healthyAt ? 200 : 503);
      response.end();
      return;
    }

    if (this.behaviour.crashOnRequest) {
      await this.stop();
      request.socket.destroy();
      return;
    }

    response.writeHead(201, { "content-type": "application/json" });
    response.end(
      JSON.stringify({
        method: request.method,
        path: request.url,
        session: request.headers["x-runtime-session-id"],
        body,
      }),
    );
  }

  async start(): Promise<void> {
    if (this.listening || this.time < this.behaviour.listensAt) {
      return;
    }

    this.listening = true;
    this.server.listen(this.socket);
    await once(this.server, "listening");
  }

  async stop(): Promise<void> {
    if (!this.listening) {
      return;
    }

    this.listening = false;
    this.server.close();
    this.server.closeAllConnections();
    await once(this.server, "close");
  }

  client(): GuestRunner {
    return new GuestRunner({
      connect: () => createConnection(this.socket),
      pause: async (milliseconds) => {
        this.time += milliseconds;
        await this.start();
      },
      timeout: (milliseconds) => AbortSignal.timeout(milliseconds),
    });
  }
}

class FixtureAbortError extends Error {
  constructor() {
    super("The fixture aborted the operation");

    this.name = "FixtureAbortError";
  }
}

function unansweredRunner(): GuestRunner {
  return new GuestRunner({
    connect: () => new Socket(),
    pause: async () => {},
    timeout: () => {
      const deadline = new AbortController();
      queueMicrotask(() => deadline.abort(new FixtureAbortError()));
      return deadline.signal;
    },
  });
}

let directory: string;
let runners: FixtureRunner[];

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "librechat-runner-"));
  runners = [];
});

afterEach(async () => {
  await Promise.all(runners.map(async (fixture) => await fixture.stop()));
  await rm(directory, { recursive: true, force: true });
});

async function runner(
  behaviour: Partial<RunnerBehaviour>,
): Promise<FixtureRunner> {
  const fixture = new FixtureRunner(join(directory, "runner.sock"), behaviour);
  runners.push(fixture);
  await fixture.start();
  return fixture;
}

function execution(): Request {
  return new Request("http://runner/api/v2/execute?stream=0", {
    method: "POST",
    headers: { "x-runtime-session-id": "rt_fixture" },
    body: JSON.stringify({ code: "true" }),
  });
}

async function readiness(operation: Promise<void>): Promise<unknown> {
  try {
    await operation;

    return "ready";
  } catch (error) {
    return error;
  }
}

it("forwards a request once the runner accepts connections on the last attempt", async () => {
  const fixture = await runner({ listensAt: 29_000 });

  const response = await fixture.client().request(execution());

  expect({
    status: response.status,
    body: await response.json(),
  }).toStrictEqual({
    status: 201,
    body: {
      method: "POST",
      path: "/api/v2/execute?stream=0",
      session: "rt_fixture",
      body: '{"code":"true"}',
    },
  });
});

it("reports a runner that never accepts connections", async () => {
  const fixture = await runner({ listensAt: 30_000 });

  await expect(fixture.client().request(execution())).rejects.toStrictEqual(
    new GuestRunnerUnavailableError(
      expect.objectContaining({ code: "ENOENT" }),
    ),
  );
});

it("does not resend a request after the runner has received it", async () => {
  const fixture = await runner({ crashOnRequest: true });

  await expect(fixture.client().request(execution())).rejects.toStrictEqual(
    new GuestRunnerConnectionError(
      expect.objectContaining({ code: "ECONNRESET" }),
    ),
  );
});

it.each([
  { listensAt: 29_000, healthyAt: 0, running: true, expected: "ready" },
  { listensAt: 0, healthyAt: 29_000, running: true, expected: "ready" },
  {
    listensAt: 30_000,
    healthyAt: 0,
    running: true,
    expected: new GuestRunnerStartupError(),
  },
  {
    listensAt: 0,
    healthyAt: 30_000,
    running: true,
    expected: new GuestRunnerStartupError(),
  },
  {
    listensAt: 0,
    healthyAt: 0,
    running: false,
    expected: new GuestRunnerStartupError(),
  },
])(
  "waits for runner health: listening at $listensAt, healthy at $healthyAt, running $running",
  async ({ listensAt, healthyAt, running, expected }) => {
    const fixture = await runner({ listensAt, healthyAt });

    const result = await readiness(
      fixture.client().waitUntilReady(() => running),
    );

    expect(result).toStrictEqual(expected);
  },
);

it("stops waiting for a connection when the request is aborted", async () => {
  const controller = new AbortController();
  const reason = new FixtureAbortError();

  const request = unansweredRunner().request(
    new Request("http://runner/api/v2/execute", {
      method: "POST",
      signal: controller.signal,
    }),
  );

  controller.abort(reason);

  await expect(request).rejects.toBe(reason);
});

it("ends a health probe at its deadline while the connection is pending", async () => {
  await expect(
    unansweredRunner().waitUntilReady(() => true),
  ).rejects.toStrictEqual(new GuestRunnerStartupError());
});
