import { X509Certificate } from "node:crypto";
import http from "node:http";
import http2 from "node:http2";
import { Readable, type Duplex } from "node:stream";
import { StatusCodes } from "http-status-codes";
import {
  CertificateAuthorityChangedError,
  ClientDisconnectedError,
  InvalidRequestTargetError,
  ListenerError,
  RequestTooLargeError,
  UnexpectedListenerError,
  UnsupportedEncodingError,
} from "./errors.ts";
import { sendError } from "./http-error.ts";
import { headersWithoutHop } from "./http-headers.ts";
import { TeamClaudeRelay } from "./relay.ts";
import { FetchTransport, type Transport } from "./transport.ts";
import type { Certificates } from "./certificates.ts";
import type { Config } from "./config.ts";
import { rewriteBody, rewriteHeaders } from "./rewrite.ts";

type Request = http.IncomingMessage | http2.Http2ServerRequest;
type Response = http.ServerResponse | http2.Http2ServerResponse;

export const healthPath = "/_claude-api-frontend/health";

async function readBody(request: Request, limit: number): Promise<Uint8Array> {
  const stream: ReadableStream<Uint8Array> = Readable.toWeb(request);
  const chunks: Uint8Array[] = [];
  let size = 0;

  for await (const chunk of stream.values({ preventCancel: true })) {
    size += chunk.byteLength;

    if (size > limit) {
      throw new RequestTooLargeError(limit);
    }

    chunks.push(chunk);
  }

  const body = new Uint8Array(size);
  let offset = 0;

  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return body;
}

function webHeaders(input: http.IncomingHttpHeaders): Headers {
  const headers = new Headers();

  for (const [key, value] of Object.entries(headersWithoutHop(input))) {
    if (value === undefined) {
      continue;
    }

    for (const entry of Array.isArray(value) ? value : [value]) {
      headers.append(key, entry);
    }
  }

  return headers;
}

function requestPath(request: Request): string {
  const raw = request.url ?? "/";
  let url: URL;

  try {
    url = new URL(raw, "https://api.anthropic.com");
  } catch {
    throw new InvalidRequestTargetError();
  }

  if (
    url.origin !== "https://api.anthropic.com" ||
    url.username.length > 0 ||
    url.password.length > 0 ||
    !raw.startsWith("/")
  ) {
    throw new InvalidRequestTargetError();
  }

  return url.pathname + url.search;
}

export interface Proxy {
  port: number;
  close(): Promise<void>;
  reloadCertificates(chain: Certificates): void;
}

export async function startProxy(
  config: Config,
  upstreamPort: number,
  chain: Certificates,
  transport: Transport = new FetchTransport(),
): Promise<Proxy> {
  const sockets = new Set<Duplex>();
  const sessions = new Set<http2.ServerHttp2Session>();
  const pending = new Set<http.ClientRequest>();
  const fingerprint = new X509Certificate(chain.ca).fingerprint256;
  const controllers = new Set<AbortController>();
  const relay = new TeamClaudeRelay({
    upstreamPort,
    timeoutMs: config.timeoutMs,
  });

  const track = (socket: Duplex): void => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
    socket.on("error", () => socket.destroy());
  };

  const forward = async (
    request: Request,
    response: Response,
  ): Promise<void> => {
    const path = requestPath(request);

    if (request.method === "GET" && path === healthPath) {
      response.statusCode = StatusCodes.OK;
      response.setHeader("content-type", "application/json");
      response.end(
        JSON.stringify({ fingerprint, upstreamPort, account: config.account }),
      );

      return;
    }

    const inference =
      request.method === "POST" && path.split("?")[0] === "/v1/messages";
    let headers = webHeaders(request.headers);
    let body: Uint8Array | ReadableStream<Uint8Array> | undefined;

    if (inference) {
      const encoding = headers.get("content-encoding");

      if (encoding !== null && encoding !== "identity") {
        request.resume();

        throw new UnsupportedEncodingError(encoding);
      }

      const original = await readBody(request, config.maxBodyBytes);

      body = rewriteBody(original);
      headers = rewriteHeaders(headers);
      headers.set("content-length", String(body.byteLength));
    } else if (request.method !== "GET" && request.method !== "HEAD") {
      body = Readable.toWeb(request);
    }

    const forwardedPath =
      inference && config.account !== null
        ? `/tc-acct/${encodeURIComponent(config.account)}${path}`
        : path;
    const controller = new AbortController();
    controllers.add(controller);

    const abort = (): void => controller.abort();
    response.once("close", abort);
    request.once("aborted", abort);

    if (response.destroyed) {
      controller.abort();
    }

    try {
      const init: RequestInit & { duplex: "half" } = {
        method: request.method,
        headers,
        body,
        signal: AbortSignal.any([
          controller.signal,
          AbortSignal.timeout(config.timeoutMs),
        ]),
        duplex: "half",
      };
      const outgoing = new globalThis.Request(
        `http://127.0.0.1:${upstreamPort}${forwardedPath}`,
        init,
      );
      const reply = await transport.send(outgoing);
      response.statusCode = reply.status;

      for (const [key, value] of reply.headers) {
        if (
          ![
            "connection",
            "keep-alive",
            "transfer-encoding",
            "content-encoding",
            "content-length",
            "set-cookie",
          ].includes(key)
        ) {
          response.setHeader(key, value);
        }
      }

      const cookies = reply.headers.getSetCookie();

      if (cookies.length > 0) {
        response.setHeader("set-cookie", cookies);
      }

      if (response instanceof http2.Http2ServerResponse) {
        response.writeHead(response.statusCode);
      } else {
        response.flushHeaders();
      }

      if (reply.body === null) {
        response.end();

        return;
      }

      await reply.body.pipeTo(
        new WritableStream<Uint8Array>({
          async write(chunk) {
            const accepted =
              response instanceof http2.Http2ServerResponse
                ? response.write(chunk)
                : response.write(chunk);

            if (accepted) {
              return;
            }

            await new Promise<void>((resolve, reject) => {
              const finish = (): void => {
                response.off("close", closed);
                resolve();
              };
              const closed = (): void => {
                response.off("drain", finish);
                reject(new ClientDisconnectedError());
              };

              response.once("drain", finish);
              response.once("close", closed);
            });
          },
          close() {
            response.end();
          },
          abort() {
            response.destroy();
          },
        }),
        { signal: controller.signal },
      );
    } finally {
      controllers.delete(controller);
      response.off("close", abort);
      request.off("aborted", abort);
    }
  };

  const handle = (request: Request, response: Response): void => {
    request.on("error", () => response.destroy());
    response.on("error", () => request.destroy());
    request.setTimeout(config.timeoutMs, () => request.destroy());
    forward(request, response)
      .catch((error: unknown) => {
        response.once("finish", () => request.destroy());
        return sendError(response, error);
      })
      .catch(() => response.destroy());
  };

  const secure = http2.createSecureServer({
    key: chain.key,
    cert: chain.cert,
    allowHTTP1: true,
    settings: { maxConcurrentStreams: 64, maxHeaderListSize: 32768 },
    handshakeTimeout: 10000,
  });
  secure.on("request", handle);
  secure.on(
    "upgrade",
    (request: http.IncomingMessage, socket: Duplex, head: Buffer) =>
      relay.upgrade(request, socket, head),
  );
  secure.on("session", (session) => {
    sessions.add(session);
    session.once("close", () => sessions.delete(session));
    session.on("error", () => session.destroy());
    session.setTimeout(config.timeoutMs, () => session.destroy());
  });
  secure.on("tlsClientError", (_error: Error, socket: Duplex) => {
    socket.destroy();
  });
  secure.on("clientError", (_error: Error, socket: Duplex) => {
    socket.destroy();
  });
  const server = http.createServer(
    {
      maxHeaderSize: 32768,
      headersTimeout: 15000,
      requestTimeout: config.timeoutMs,
    },
    (request, response) => {
      if (/^https?:\/\//i.test(request.url ?? "")) {
        relay.http(request, response);

        return;
      }

      handle(request, response);
    },
  );
  server.on("upgrade", (request, socket, head) =>
    relay.upgrade(request, socket, head),
  );
  server.maxConnections = 128;
  server.on("connection", track);
  server.on("clientError", (_error, socket) => socket.destroy());
  server.on("connect", (request, socket, head) => {
    if (/^api\.anthropic\.com:443$/i.test(request.url ?? "")) {
      socket.write(`HTTP/1.1 ${StatusCodes.OK} Connection Established\r\n\r\n`);
      if (head.length > 0) {
        socket.unshift(head);
      }
      secure.emit("connection", socket);
      return;
    }

    const tunnel = http.request({
      hostname: "127.0.0.1",
      port: upstreamPort,
      method: "CONNECT",
      path: request.url,
      headers: headersWithoutHop(request.headers),
      agent: false,
    });
    pending.add(tunnel);
    tunnel.once("close", () => pending.delete(tunnel));
    tunnel.setTimeout(10000, () => tunnel.destroy());
    socket.once("close", () => tunnel.destroy());
    tunnel.on("connect", (reply, target, pendingHead) => {
      track(target);
      if (reply.statusCode !== StatusCodes.OK) {
        socket.end(`HTTP/1.1 ${StatusCodes.BAD_GATEWAY} Bad Gateway\r\n\r\n`);
        target.destroy();
        return;
      }
      socket.write(`HTTP/1.1 ${StatusCodes.OK} Connection Established\r\n\r\n`);
      if (head.length > 0) {
        target.write(head);
      }
      if (pendingHead.length > 0) {
        socket.write(pendingHead);
      }
      target.setTimeout(config.timeoutMs, () => target.destroy());
      socket.pipe(target);
      target.pipe(socket);
      socket.once("close", () => target.destroy());
      target.once("close", () => socket.destroy());
    });
    tunnel.on("error", () => socket.destroy());
    tunnel.end();
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", (cause: Error) =>
      reject(new ListenerError(config.port, { cause })),
    );
    server.listen(config.port, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new UnexpectedListenerError();
  }
  return {
    port: address.port,
    reloadCertificates(replacement) {
      if (new X509Certificate(replacement.ca).fingerprint256 !== fingerprint) {
        throw new CertificateAuthorityChangedError();
      }

      secure.setSecureContext({ key: replacement.key, cert: replacement.cert });
    },
    async close() {
      relay.close();
      for (const session of sessions) {
        session.destroy();
      }
      for (const socket of sockets) {
        socket.destroy();
      }
      for (const request of pending) {
        request.destroy();
      }
      for (const controller of controllers) {
        controller.abort();
      }
      server.closeAllConnections();
      await new Promise<void>((resolve) => {
        server.close(() => resolve());
      });
    },
  };
}
