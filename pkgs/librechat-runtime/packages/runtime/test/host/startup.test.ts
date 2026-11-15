import { expect, it } from "vitest";
import {
  waitForSecrets,
  ReadinessWaiter,
  SecretReadinessTimeoutError,
  SecretDecryptionError,
  fileServerReady,
} from "#runtime/host/startup";

it("rejects an unrelated service's successful health response", async () => {
  const ready = await fileServerReady("http://file-server", {
    token: "fixture",
    fetch: async () => Response.json({ status: true }),
  });
  expect(ready).toBe(false);
});

it.each([
  { serverToken: "fixture", ready: true },
  { serverToken: "another-token", ready: false },
])(
  "checks protected file listing against a server expecting $serverToken",
  async ({ serverToken, ready: expected }) => {
    const ready = await fileServerReady("http://file-server", {
      token: "fixture",
      fetch: async (_url, options) => {
        const token = new Headers(options?.headers).get(
          "X-CodeAPI-Internal-Token",
        );
        return Response.json([], { status: token === serverToken ? 200 : 401 });
      },
    });
    expect(ready).toBe(expected);
  },
);

it("rejects a service that returns an empty list without authentication", async () => {
  const ready = await fileServerReady("http://file-server", {
    token: "fixture",
    fetch: async () => Response.json([]),
  });
  expect(ready).toBe(false);
});

const program = "/nix/store/current-sops";

function status(
  options: {
    program?: string;
    state?: string;
    runs?: number;
    exit?: number;
  } = {},
): string {
  return `\tprogram = ${options.program ?? program}\n\tstate = ${options.state ?? "not running"}\n\truns = ${options.runs ?? 1}\n\tlast exit code = ${options.exit ?? 0}\n`;
}

class Clock {
  time = 0;

  private readonly step: number;

  constructor(step: number) {
    this.step = step;
  }

  readonly now = (): number => this.time;

  readonly pause = async (): Promise<void> => {
    this.time += this.step;
  };
}

it("waits for the current secret job to finish before startup", async () => {
  const clock = new Clock(1000);
  const job = (): string => {
    if (clock.time < 1000) {
      return "";
    }
    if (clock.time < 2000) {
      return status({ program: "/nix/store/old-sops" });
    }
    if (clock.time < 3000) {
      return status({ runs: 0 });
    }
    if (clock.time < 4000) {
      return status({ state: "running" });
    }
    return status();
  };

  await waitForSecrets(program, {
    now: clock.now,
    status: async () => job(),
    pause: clock.pause,
  });

  expect(clock.time).toBe(4000);
});

it("reports failed decryption before starting services", async () => {
  await expect(
    waitForSecrets(program, {
      now: () => 0,
      status: async () => status({ exit: 1 }),
      pause: async () => {},
    }),
  ).rejects.toStrictEqual(new SecretDecryptionError());
});

it("bounds the wait for a missing secret job", async () => {
  const clock = new Clock(10_000);

  await expect(
    waitForSecrets(program, {
      now: clock.now,
      status: async () => "",
      pause: clock.pause,
    }),
  ).rejects.toStrictEqual(new SecretReadinessTimeoutError());

  expect(clock.time).toBe(30_000);
});

it("recognises a launchd job configured with program arguments", async () => {
  await expect(
    waitForSecrets(program, {
      now: () => 0,
      status: async () =>
        `\targuments = {\n\t\t${program}\n\t}\n\tstate = not running\n\truns = 1\n\tlast exit code = 0\n`,
      pause: async () => {},
    }),
  ).resolves.toBeUndefined();
});

it.each([0, 2])("limits readiness polling to %i retries", async (retries) => {
  const clock = new Clock(1);

  const waiter = new ReadinessWaiter({
    signal: new AbortController().signal,
    pause: clock.pause,
  });

  await expect(
    waiter.wait(async () => false, {
      attempts: retries,
      TimeoutError: SecretReadinessTimeoutError,
    }),
  ).rejects.toStrictEqual(new SecretReadinessTimeoutError());

  expect(clock.time).toBe(retries);
});

it("waits without a limit until the probe succeeds", async () => {
  const clock = new Clock(1);

  const waiter = new ReadinessWaiter({
    signal: new AbortController().signal,
    pause: clock.pause,
  });

  await waiter.wait(async () => clock.time >= 10_000);

  expect(clock.time).toBe(10_000);
});

it.each(["before", "during"])(
  "cancels unlimited readiness polling %s a delay",
  async (stage) => {
    const controller = new AbortController();

    const reason = new DOMException("Readiness cancelled", "AbortError");

    const clock = new Clock(1);

    const waiter = new ReadinessWaiter({
      signal: controller.signal,
      pause: async () => {
        await clock.pause();

        controller.abort(reason);
      },
    });

    if (stage === "before") {
      controller.abort(reason);
    }

    const readyAt = stage === "before" ? 0 : 1;

    await expect(waiter.wait(async () => clock.time >= readyAt)).rejects.toBe(
      reason,
    );

    expect(clock.time).toBe(readyAt);
  },
);
