import http from "node:http";
import type { Socket } from "node:net";
import type { Duplex } from "node:stream";
import { StatusCodes } from "http-status-codes";
import { InvalidRequestTargetError, UpstreamError } from "./errors.ts";
import { httpFailure, sendError } from "./http-error.ts";
import { headersWithoutHop } from "./http-headers.ts";

interface RelayOptions {
  upstreamPort: number;
  timeoutMs: number;
}

function validateTarget(target: string, form: "absolute" | "origin"): void {
  let url: URL;

  try {
    url =
      form === "absolute"
        ? new URL(target)
        : new URL(target, "https://api.anthropic.com");
  } catch {
    throw new InvalidRequestTargetError();
  }

  if (url.username.length > 0 || url.password.length > 0) {
    throw new InvalidRequestTargetError();
  }

  if (
    form === "absolute" &&
    (url.protocol === "http:" || url.protocol === "https:")
  ) {
    return;
  }

  if (
    form === "origin" &&
    target.startsWith("/") &&
    url.origin === "https://api.anthropic.com"
  ) {
    return;
  }

  throw new InvalidRequestTargetError();
}

function responseHead(
  status: number,
  headers: http.IncomingHttpHeaders,
): string {
  const lines = Object.entries(headers).flatMap(([key, value]) => {
    if (value === undefined) {
      return [];
    }

    return (Array.isArray(value) ? value : [value]).map(
      (entry) => `${key}: ${entry}\r\n`,
    );
  });

  return `HTTP/1.1 ${status} Proxy Response\r\n${lines.join("")}\r\n`;
}

export class TeamClaudeRelay {
  private readonly options: RelayOptions;
  private readonly requests = new Set<http.ClientRequest>();
  private readonly sockets = new Set<Duplex>();

  constructor(options: RelayOptions) {
    this.options = options;
  }

  private open(
    request: http.IncomingMessage,
    headers: http.IncomingHttpHeaders,
  ): http.ClientRequest {
    const upstream = http.request({
      hostname: "127.0.0.1",
      port: this.options.upstreamPort,
      path: request.url,
      method: request.method,
      headers,
      agent: false,
      maxHeaderSize: 32768,
    });

    this.requests.add(upstream);
    upstream.once("close", () => this.requests.delete(upstream));
    upstream.setTimeout(this.options.timeoutMs, () =>
      upstream.destroy(
        new UpstreamError({
          cause: { kind: "timeout", timeoutMs: this.options.timeoutMs },
        }),
      ),
    );

    return upstream;
  }

  http(request: http.IncomingMessage, response: http.ServerResponse): void {
    try {
      validateTarget(request.url ?? "", "absolute");

      const headers = headersWithoutHop(request.headers);
      headers.host = request.headers.host;
      const upstream = this.open(request, headers);

      request.on("error", () => upstream.destroy());
      request.once("aborted", () => upstream.destroy());
      response.on("error", () => upstream.destroy());
      response.once("close", () => upstream.destroy());
      upstream.on("error", (error: Error) => {
        sendError(response, error);
      });
      upstream.on("response", (reply) => {
        reply.on("error", () => response.destroy());
        response.writeHead(
          reply.statusCode ?? StatusCodes.BAD_GATEWAY,
          headersWithoutHop(reply.headers),
        );
        reply.pipe(response);
      });
      request.pipe(upstream);
    } catch (error) {
      request.resume();
      sendError(response, error);
    }
  }

  upgrade(request: http.IncomingMessage, socket: Duplex, head: Buffer): void {
    this.track(socket);
    let established = false;

    const fail = (error: unknown): void => {
      if (established) {
        socket.destroy();

        return;
      }

      const reply = httpFailure(error);
      const headers = { ...reply.headers, connection: "close" };

      socket.end(
        responseHead(reply.status, headers) + JSON.stringify(reply.body),
      );
    };

    try {
      validateTarget(request.url ?? "", "origin");

      const headers = headersWithoutHop(request.headers);
      headers.host = `127.0.0.1:${this.options.upstreamPort}`;
      headers.connection = "Upgrade";
      headers.upgrade = request.headers.upgrade;
      const upstream = this.open(request, headers);

      socket.once("close", () => upstream.destroy());
      upstream.on("error", fail);
      upstream.on(
        "upgrade",
        (reply: http.IncomingMessage, target: Socket, pendingHead: Buffer) => {
          established = true;
          this.track(target);
          socket.write(
            responseHead(
              reply.statusCode ?? StatusCodes.SWITCHING_PROTOCOLS,
              reply.headers,
            ),
          );

          if (head.length > 0) {
            target.write(head);
          }

          if (pendingHead.length > 0) {
            socket.write(pendingHead);
          }

          target.setTimeout(this.options.timeoutMs, () => target.destroy());
          socket.pipe(target);
          target.pipe(socket);
          socket.once("close", () => target.destroy());
          target.once("close", () => socket.destroy());
        },
      );
      upstream.on("response", (reply) => {
        established = true;
        const responseHeaders = headersWithoutHop(reply.headers);
        responseHeaders.connection = "close";
        socket.write(
          responseHead(
            reply.statusCode ?? StatusCodes.BAD_GATEWAY,
            responseHeaders,
          ),
        );
        reply.on("error", () => socket.destroy());
        reply.pipe(socket);
      });
      upstream.end();
    } catch (error) {
      fail(error);
    }
  }

  private track(socket: Duplex): void {
    this.sockets.add(socket);
    socket.once("close", () => this.sockets.delete(socket));
    socket.on("error", () => socket.destroy());
  }

  close(): void {
    for (const request of this.requests) {
      request.destroy();
    }

    for (const socket of this.sockets) {
      socket.destroy();
    }
  }
}
