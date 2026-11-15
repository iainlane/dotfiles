import { expect, it } from "vitest";
import {
  GuestServiceProcess,
  GuestStartupCleanupError,
} from "#runtime/guest/guest-service";
import type { ManagedProcess } from "#runtime/platform/processes";

class FixtureStartupError extends Error {
  constructor() {
    super("The fixture service did not become ready");

    this.name = "FixtureStartupError";
  }
}

class FixtureCleanupError extends Error {
  constructor() {
    super("The fixture service could not stop");

    this.name = "FixtureCleanupError";
  }
}

class ServiceAlreadyRunningError extends Error {
  constructor() {
    super("Another instance of the fixture service is still running");

    this.name = "ServiceAlreadyRunningError";
  }
}

const command = { executable: "/fixture", args: [] };

class FixtureProcess implements ManagedProcess {
  readonly exited = Promise.withResolvers<void>().promise;
  private active = true;

  running(): boolean {
    return this.active;
  }

  async stop(): Promise<void> {
    this.active = false;
  }
}

class FixtureHost {
  private readonly processes: FixtureProcess[] = [];
  stoppable = true;

  async start(): Promise<ManagedProcess> {
    if (this.processes.some((child) => child.running())) {
      throw new ServiceAlreadyRunningError();
    }

    const child = new FixtureProcess();

    this.processes.push(child);

    return child;
  }

  async stop(child: ManagedProcess): Promise<void> {
    if (!this.stoppable) {
      throw new FixtureCleanupError();
    }

    await child.stop();
  }

  running(): FixtureProcess[] {
    return this.processes.filter((child) => child.running());
  }
}

function fixture() {
  const host = new FixtureHost();

  return { host, service: new GuestServiceProcess(host) };
}

it("stops a failed startup before retrying and publishes readiness only after success", async () => {
  const { host, service } = fixture();

  await expect(
    service.start(command, async () => {
      throw new FixtureStartupError();
    }),
  ).rejects.toStrictEqual(new FixtureStartupError());

  const readyAfterFailure = service.isReady();

  const child = await service.start(command, async () => {});

  expect({
    running: host.running(),
    readyAfterFailure,
    ready: service.isReady(),
  }).toStrictEqual({
    running: [child],
    readyAfterFailure: false,
    ready: true,
  });
});

it("retries failed cleanup before starting another process", async () => {
  const { host, service } = fixture();
  host.stoppable = false;

  await expect(
    service.start(command, async () => {
      throw new FixtureStartupError();
    }),
  ).rejects.toStrictEqual(
    new GuestStartupCleanupError(
      new FixtureStartupError(),
      new FixtureCleanupError(),
    ),
  );

  const readyAfterFailure = service.isReady();

  host.stoppable = true;

  const child = await service.start(command, async () => {});

  expect({
    running: host.running(),
    readyAfterFailure,
  }).toStrictEqual({
    running: [child],
    readyAfterFailure: false,
  });
});

it("shares pending startup and reuses only a ready process", async () => {
  const { host, service } = fixture();

  const entered = Promise.withResolvers<void>();
  const ready = Promise.withResolvers<void>();

  const first = service.start(command, async () => {
    entered.resolve();

    await ready.promise;
  });

  await entered.promise;

  const readyBeforeInitialisation = service.isReady();

  const second = service.start(command, async () => {
    throw new FixtureStartupError();
  });

  ready.resolve();

  const results = await Promise.all([first, second]);

  const reused = await service.start(command, async () => {
    throw new FixtureStartupError();
  });

  await service.stop();

  expect({
    running: host.running(),
    readyBeforeInitialisation,
    ready: service.isReady(),
    results,
    reused,
  }).toStrictEqual({
    running: [],
    readyBeforeInitialisation: false,
    ready: false,
    results: [reused, reused],
    reused: results[0],
  });
});
