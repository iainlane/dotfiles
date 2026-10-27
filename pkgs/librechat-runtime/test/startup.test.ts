import { expect, it } from "vitest";
import {
  waitForSecrets,
  ReadinessWaiter,
  SecretReadinessTimeoutError,
  SecretDecryptionError,
} from "../src/startup.ts";

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

it("waits for the current secret job to finish before startup", async () => {
  const replies = [
    "",
    status({ program: "/nix/store/old-sops" }),
    status({ runs: 0 }),
    status({ state: "running" }),
    status(),
  ];

  const calls: string[] = [];

  await waitForSecrets(program, {
    now: () => 0,
    status: async () => {
      calls.push("status");

      return replies.shift() ?? "";
    },
    pause: async () => {
      calls.push("pause");
    },
  });

  expect(calls).toStrictEqual([
    "status",
    "pause",
    "status",
    "pause",
    "status",
    "pause",
    "status",
    "pause",
    "status",
  ]);
});

it("reports failed decryption before starting services", async () => {
  await expect(
    waitForSecrets(program, {
      now: () => 0,
      status: async () => status({ exit: 1 }),
      pause: async () => {},
    }),
  ).rejects.toThrow(SecretDecryptionError);
});

it("bounds the wait for a missing secret job", async () => {
  let pauses = 0;

  await expect(
    waitForSecrets(program, {
      now: () => pauses * 10_000,
      status: async () => "",
      pause: async () => {
        pauses += 1;
      },
    }),
  ).rejects.toThrow(SecretReadinessTimeoutError);

  expect(pauses).toBe(3);
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
  const events: string[] = [];

  const waiter = new ReadinessWaiter({
    signal: new AbortController().signal,
    pause: async () => {
      events.push("pause");
    },
  });

  await expect(
    waiter.wait(
      async () => {
        events.push("probe");

        return false;
      },
      SecretReadinessTimeoutError,
      retries,
    ),
  ).rejects.toThrow(SecretReadinessTimeoutError);

  expect(events).toStrictEqual([
    ...Array.from({ length: retries }, () => ["probe", "pause"]).flat(),
    "probe",
  ]);
});

it("waits indefinitely for account bootstrap until the probe succeeds", async () => {
  let probes = 0;

  let pauses = 0;

  const waiter = new ReadinessWaiter({
    signal: new AbortController().signal,
    pause: async () => {
      pauses += 1;
    },
  });

  await waiter.wait(
    async () => {
      probes += 1;

      return probes === 10_001;
    },
    SecretReadinessTimeoutError,
    Number.POSITIVE_INFINITY,
  );

  expect({ probes, pauses }).toStrictEqual({ probes: 10_001, pauses: 10_000 });
});

it.each(["before", "during"])(
  "cancels indefinite readiness polling %s a delay",
  async (stage) => {
    const controller = new AbortController();

    const events: string[] = [];

    const waiter = new ReadinessWaiter({
      signal: controller.signal,
      pause: async () => {
        events.push("pause");

        controller.abort();
      },
    });

    if (stage === "before") {
      controller.abort();
    }

    await expect(
      waiter.wait(
        async () => {
          events.push("probe");

          return false;
        },
        SecretReadinessTimeoutError,
        Number.POSITIVE_INFINITY,
      ),
    ).rejects.toMatchObject({ name: "AbortError" });

    expect(events).toStrictEqual(stage === "before" ? [] : ["probe", "pause"]);
  },
);
