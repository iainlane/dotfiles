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

  private readonly interval: number;

  constructor(interval: number) {
    this.interval = interval;
  }

  readonly now = (): number => this.time;

  readonly pause = async (): Promise<void> => {
    this.time += this.interval;
  };
}

async function outcome(wait: Promise<void>): Promise<unknown> {
  try {
    await wait;

    return "ready";
  } catch (error) {
    return error;
  }
}

it.each([
  { finished: 30_000, expected: "ready" },
  { finished: 30_001, expected: new SecretReadinessTimeoutError() },
])(
  "waits up to 30 seconds for a job that finishes at $finished ms",
  async ({ finished, expected }) => {
    const clock = new Clock(1000);
    const job = (): string => {
      if (clock.time < finished) {
        return status({ state: "running" });
      }
      return status();
    };

    const result = waitForSecrets(program, {
      now: clock.now,
      status: async () => job(),
      pause: clock.pause,
    });

    expect(await outcome(result)).toStrictEqual(expected);
  },
);

it.each([
  { job: "missing", status: "" },
  {
    job: "from an earlier generation",
    status: status({ program: "/nix/store/old-sops" }),
  },
  { job: "that has not run", status: status({ runs: 0 }) },
  { job: "still running", status: status({ state: "running" }) },
])("keeps waiting for a secret job $job", async ({ status: current }) => {
  const clock = new Clock(1000);

  await expect(
    waitForSecrets(program, {
      now: clock.now,
      status: async () => current,
      pause: clock.pause,
    }),
  ).rejects.toStrictEqual(new SecretReadinessTimeoutError());
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

it.each([
  { retries: 0, ready: 0, expected: "ready" },
  { retries: 0, ready: 1000, expected: new SecretReadinessTimeoutError() },
  { retries: 2, ready: 2000, expected: "ready" },
  { retries: 2, ready: 3000, expected: new SecretReadinessTimeoutError() },
])(
  "allows $retries retries for a probe ready at $ready ms",
  async ({ retries, ready, expected }) => {
    const clock = new Clock(1000);

    const waiter = new ReadinessWaiter({
      signal: new AbortController().signal,
      pause: clock.pause,
    });

    const result = waiter.wait(async () => clock.time >= ready, {
      attempts: retries,
      TimeoutError: SecretReadinessTimeoutError,
    });

    expect(await outcome(result)).toStrictEqual(expected);
  },
);

it("waits without a limit until the probe succeeds", async () => {
  const clock = new Clock(1000);

  const waiter = new ReadinessWaiter({
    signal: new AbortController().signal,
    pause: clock.pause,
  });

  await expect(
    waiter.wait(async () => clock.time >= 10_000_000),
  ).resolves.toBeUndefined();
});

it.each(["before", "during"])(
  "cancels unlimited readiness polling %s a delay",
  async (stage) => {
    const controller = new AbortController();

    const reason = new DOMException("Readiness cancelled", "AbortError");

    const clock = new Clock(1000);

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

    const ready = stage === "before" ? 0 : 1000;

    await expect(waiter.wait(async () => clock.time >= ready)).rejects.toBe(
      reason,
    );
  },
);
