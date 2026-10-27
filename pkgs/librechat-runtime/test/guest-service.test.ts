import { expect, it } from "vitest";
import { GuestServiceProcess } from "../src/guest-service.ts";
import type { ManagedProcess } from "../src/processes.ts";

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

const command = { executable: "/fixture", args: [] };

function fixture(cleanupFailures = 0) {
  const events: string[] = [];
  const children: ManagedProcess[] = [];

  const service = new GuestServiceProcess({
    start: async () => {
      const id = children.length + 1;
      let running = true;

      const child: ManagedProcess = {
        exited: Promise.withResolvers<void>().promise,
        running: () => running,
        stop: async () => {
          events.push(`stop:${id}`);

          running = false;
        },
      };

      children.push(child);
      events.push(`start:${id}`);

      return child;
    },
    stop: async (child) => {
      if (cleanupFailures > 0) {
        cleanupFailures -= 1;

        events.push("cleanup-failed");

        throw new FixtureCleanupError();
      }

      await child.stop();
    },
  });

  return { service, events, children };
}

it("stops a failed startup before retrying and publishes readiness only after success", async () => {
  const { service, events, children } = fixture();

  await expect(
    service.start(command, async () => {
      events.push("initialise:1");

      throw new FixtureStartupError();
    }),
  ).rejects.toBeInstanceOf(FixtureStartupError);

  const readyAfterFailure = service.isReady();

  const child = await service.start(command, async () => {
    events.push("initialise:2");
  });

  expect({
    events,
    readyAfterFailure,
    ready: service.isReady(),
    child,
  }).toStrictEqual({
    events: ["start:1", "initialise:1", "stop:1", "start:2", "initialise:2"],
    readyAfterFailure: false,
    ready: true,
    child: children[1],
  });
});

it("retries failed cleanup before starting another process", async () => {
  const { service, events, children } = fixture(1);

  await expect(
    service.start(command, async () => {
      throw new FixtureStartupError();
    }),
  ).rejects.toBeInstanceOf(FixtureCleanupError);

  const readyAfterFailure = service.isReady();

  const child = await service.start(command, async () => {});

  expect({ events, readyAfterFailure, child }).toStrictEqual({
    events: ["start:1", "cleanup-failed", "stop:1", "start:2"],
    readyAfterFailure: false,
    child: children[1],
  });
});

it("shares pending startup and reuses only a ready process", async () => {
  const { service, events, children } = fixture();

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
    events,
    readyBeforeInitialisation,
    ready: service.isReady(),
    results,
    reused,
  }).toStrictEqual({
    events: ["start:1", "stop:1"],
    readyBeforeInitialisation: false,
    ready: false,
    results: [children[0], children[0]],
    reused: children[0],
  });
});
