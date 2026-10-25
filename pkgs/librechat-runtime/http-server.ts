import { StatusCodes } from "http-status-codes";
import { createServer, type Server } from "node:http";
import { Readable, Transform, type TransformCallback } from "node:stream";
import { pipeline } from "node:stream/promises";

export class RequestBodyLimitError extends Error {
  constructor() {
    super("Request body exceeds the service limit");

    this.name = "RequestBodyLimitError";
  }
}

class BodyLimit extends Transform {
  private bytes = 0;
  private readonly limit: number;

  constructor(limit: number) {
    super();

    this.limit = limit;
  }

  override _transform(
    chunk: unknown,
    _encoding: BufferEncoding,
    callback: TransformCallback,
  ): void {
    if (!Buffer.isBuffer(chunk)) {
      callback(new RequestBodyLimitError());

      return;
    }

    this.bytes += chunk.length;

    if (this.bytes > this.limit) {
      callback(new RequestBodyLimitError());

      return;
    }

    callback(null, chunk);
  }
}

export interface HttpServiceOptions {
  handler(request: Request): Promise<Response>;

  onError(error: unknown): void;
  maxBodyBytes?: number;
}

export function httpService(options: HttpServiceOptions): Server {
  return createServer((incoming, outgoing) => {
    const abort = new AbortController();

    incoming.once("aborted", () => abort.abort());

    outgoing.once("close", () => {
      if (!outgoing.writableEnded) {
        abort.abort();
      }
    });

    const headers = new Headers();

    for (const [name, value] of Object.entries(incoming.headers)) {
      if (value !== undefined) {
        headers.set(name, Array.isArray(value) ? value.join(", ") : value);
      }
    }

    const method = incoming.method ?? "GET";

    const init: RequestInit & { duplex: "half" } = {
      method,
      headers,
      signal: abort.signal,
      duplex: "half",
    };

    if (!["GET", "HEAD"].includes(method)) {
      const limited = incoming.pipe(
        new BodyLimit(options.maxBodyBytes ?? 16 * 1024 * 1024),
      );

      incoming.once("error", (error: Error) => limited.destroy(error));

      init.body = Readable.toWeb(limited);
    }

    const request = new Request(`http://service${incoming.url ?? "/"}`, init);
    options
      .handler(request)
      .then(async (response) => {
        outgoing.writeHead(
          response.status,
          Object.fromEntries(response.headers),
        );

        if (response.body === null) {
          outgoing.end();

          return null;
        }

        await pipeline(Readable.fromWeb(response.body), outgoing);

        return null;
      })
      .catch((error: unknown) => {
        options.onError(error);

        if (outgoing.headersSent) {
          outgoing.destroy();

          return;
        }

        outgoing.writeHead(
          error instanceof RequestBodyLimitError
            ? StatusCodes.REQUEST_TOO_LONG
            : StatusCodes.INTERNAL_SERVER_ERROR,
          { "content-type": "application/json" },
        );

        outgoing.end(
          JSON.stringify({
            error: error instanceof Error ? error.name : "InternalServiceError",
          }),
        );
      });
  });
}
