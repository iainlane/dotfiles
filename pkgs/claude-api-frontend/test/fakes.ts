import type { CertificateCommand } from "#frontend/certificates";
import { loadConfig, type Config } from "#frontend/config";
import { CertificateCommandError } from "#frontend/errors";
import type { Transport } from "#frontend/transport";

export async function frontendConfig(fields: object): Promise<Config> {
  return await loadConfig("/fixture/frontend.json", {
    readText: async (_path: string): Promise<string> => JSON.stringify(fields),
  });
}

export class FakeTransport implements Transport {
  readonly requests: Request[] = [];
  readonly respond: (request: Request) => Response;

  constructor(respond: (request: Request) => Response) {
    this.respond = respond;
  }

  async snapshot(): Promise<object[]> {
    return await Promise.all(
      this.requests.map(async (request) => ({
        url: request.url,
        method: request.method,
        headers: Object.fromEntries(request.headers),
        body: await request.text(),
      })),
    );
  }

  async send(request: Request): Promise<Response> {
    this.requests.push(request);

    return this.respond(request);
  }
}

export class FailingCertificateCommand implements CertificateCommand {
  async run(_arguments: readonly string[]): Promise<void> {
    throw new CertificateCommandError({
      cause: { code: "FAKE_OPENSSL_FAILURE" },
    });
  }
}

export class IncompleteSocketFrameError extends Error {
  readonly expected: number;
  readonly received: number;

  constructor(expected: number, received: number) {
    super(`Socket closed after ${received} of ${expected} frame bytes`);
    this.name = "IncompleteSocketFrameError";
    this.expected = expected;
    this.received = received;
  }
}

export class FrontendEarlyExitError extends Error {
  readonly code: number | null;

  constructor(code: number | null, stderr: string) {
    super(`Frontend exited before listening (${code}): ${stderr}`);
    this.name = "FrontendEarlyExitError";
    this.code = code;
  }
}

export class FrontendStartupTimeoutError extends Error {
  constructor(stderr: string) {
    super(`Frontend did not start listening: ${stderr}`);
    this.name = "FrontendStartupTimeoutError";
  }
}
