export interface SecretStartupDependencies {
  status(): Promise<string>;

  now(): number;

  pause(): Promise<void>;
}

export class SecretDecryptionError extends Error {
  constructor() {
    super("sops-nix failed to decrypt secrets; check the sops-nix launchd job");

    this.name = "SecretDecryptionError";
  }
}

export class SecretReadinessTimeoutError extends Error {
  constructor() {
    super(
      "sops-nix did not finish within 30 seconds; check the sops-nix launchd job",
    );

    this.name = "SecretReadinessTimeoutError";
  }
}

/** Wait for the configured launchd secret job before reading credentials. */
export async function waitForSecrets(
  expectedProgram: string,
  dependencies: SecretStartupDependencies,
): Promise<void> {
  await pollSecrets(expectedProgram, dependencies, dependencies.now() + 30_000);
}

async function pollSecrets(
  expectedProgram: string,
  dependencies: SecretStartupDependencies,
  deadline: number,
): Promise<void> {
  const status = await dependencies.status();
  const program = status.match(/^\tprogram = (.+)$/mu)?.[1];
  const argumentsText =
    status.match(/^\targuments = \{\n([\s\S]*?)^\t\}/mu)?.[1] ?? "";
  const current =
    program === expectedProgram ||
    argumentsText.split(/\s+/u).includes(expectedProgram);
  const stopped = /^\tstate = not running$/mu.test(status);
  const started = /^\truns = [1-9][0-9]*$/mu.test(status);

  if (current && stopped && started) {
    if (/^\tlast exit code = 0$/mu.test(status)) {
      return;
    }

    throw new SecretDecryptionError();
  }

  if (dependencies.now() >= deadline) {
    throw new SecretReadinessTimeoutError();
  }

  await dependencies.pause();

  await pollSecrets(expectedProgram, dependencies, deadline);
}

interface ReadinessDependencies {
  signal: AbortSignal;

  pause(): Promise<void>;
}

export class ReadinessWaiter {
  private readonly dependencies: ReadinessDependencies;

  constructor(dependencies: ReadinessDependencies) {
    this.dependencies = dependencies;
  }

  async wait(
    probe: () => Promise<boolean>,
    TimeoutError: new () => Error,
    remaining = 90,
  ): Promise<void> {
    while (true) {
      this.dependencies.signal.throwIfAborted();

      // oxlint-disable-next-line no-await-in-loop -- A retry requires the previous probe to finish.
      if (await probe()) {
        return;
      }

      if (remaining === 0) {
        throw new TimeoutError();
      }

      // oxlint-disable-next-line no-await-in-loop -- Delay each retry after the failed probe.
      await this.dependencies.pause();

      remaining -= 1;
    }
  }
}
interface HttpProbeOptions {
  fetch?: typeof globalThis.fetch;
  timeoutMs?: number;
}

export async function httpReady(
  url: string,
  options: HttpProbeOptions = {},
): Promise<boolean> {
  try {
    const response = await (options.fetch ?? globalThis.fetch)(url, {
      signal: AbortSignal.timeout(options.timeoutMs ?? 500),
    });

    await response.body?.cancel();

    return response.ok;
  } catch {
    return false;
  }
}
