import type { CertificateCommand } from "../src/certificates.ts";
import { CertificateCommandError, FrontendError } from "../src/errors.ts";
import type { Transport } from "../src/transport.ts";

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

export function errorSnapshot(error: unknown): object {
  if (!(error instanceof FrontendError)) {
    throw error;
  }

  return { data: error.toJSON(), cause: error.cause };
}
