import type { CertificateCommand } from "#frontend/certificates";
import { loadConfig, type Config } from "#frontend/config";
import { CertificateCommandError } from "#frontend/errors";
import type { Transport } from "#frontend/transport";
import { expect } from "vitest";

const anyString: unknown = expect.any(String);

/** Headers that Node's `fetch` adds to every request that it sends. */
export const fetchHeaders = {
  accept: anyString,
  "accept-encoding": anyString,
  "accept-language": anyString,
  "sec-fetch-mode": anyString,
};

/** Headers that Node's HTTP server adds to every response. */
export const serverHeaders = {
  connection: anyString,
  "keep-alive": anyString,
  date: anyString,
};

export async function frontendConfig(fields: object): Promise<Config> {
  return await loadConfig("/fixture/frontend.json", {
    readText: async (_path: string): Promise<string> => JSON.stringify(fields),
  });
}

/** Answers with the URL, method, headers and body of the request. */
export async function echo(
  request: Request,
  init?: ResponseInit,
): Promise<Response> {
  return Response.json(
    {
      url: request.url,
      method: request.method,
      headers: Object.fromEntries(request.headers),
      body: await request.text(),
    },
    init,
  );
}

export class FakeTransport implements Transport {
  readonly respond: (request: Request) => Response | Promise<Response>;

  constructor(respond: (request: Request) => Response | Promise<Response>) {
    this.respond = respond;
  }

  async send(request: Request): Promise<Response> {
    return await this.respond(request);
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
