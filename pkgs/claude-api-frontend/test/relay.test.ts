import http from "node:http";
import tls from "node:tls";
import type { Duplex } from "node:stream";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { StatusCodes } from "http-status-codes";
import { afterEach, expect, it } from "vitest";
import { certificates } from "../src/certificates.ts";
import { configSchema } from "../src/config.ts";
import { startProxy } from "../src/proxy.ts";

const cleanup: (() => Promise<unknown>)[] = [];
const date = "Thu, 01 Jan 1970 00:00:00 GMT";

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "frontend-relay-"));
  cleanup.push(() => rm(directory, { recursive: true, force: true }));
  const chain = await certificates(directory);
  const upstream = http.createServer();

  await new Promise<void>((resolve, reject) => {
    upstream.once("error", reject);
    upstream.listen(0, "127.0.0.1", resolve);
  });
  cleanup.push(async () => {
    upstream.closeAllConnections();
    await new Promise<void>((resolve) => {
      upstream.close(() => resolve());
    });
  });

  const address = upstream.address();

  if (address === null || typeof address === "string") {
    throw new Error("Expected a TCP listener");
  }

  const config = configSchema.parse({
    teamclaudeConfigFile: "/unused",
    stateDirectory: directory,
  });
  const proxy = await startProxy({ ...config, port: 0 }, address.port, chain);
  cleanup.push(() => proxy.close());

  return { upstream, proxy, chain, upstreamPort: address.port };
}

afterEach(async () => {
  await cleanup.toReversed().reduce(async (previous, close) => {
    await previous;
    await close();
  }, Promise.resolve());
  cleanup.length = 0;
});

it.each(["GET", "POST"])(
  "delegates absolute-form %s requests to TeamClaude unchanged",
  async (method) => {
    const { upstream, proxy } = await fixture();
    const requests: object[] = [];
    const target = "http://example.org/v1/messages?source=proxy";
    const body =
      method === "POST" ? "x-anthropic-billing-header: preserve this body" : "";
    const headers = {
      host: "example.org",
      connection: "close",
      "user-agent": "claude-cli/2.1.310 (external, cli)",
      "anthropic-beta": "claude-code-20250219,other-beta",
      "content-length": String(Buffer.byteLength(body)),
    };
    const compressed = new Uint8Array(
      await new Response(
        new Blob(["upstream bytes"])
          .stream()
          .pipeThrough(new CompressionStream("gzip")),
      ).arrayBuffer(),
    );
    const responseHeaders = {
      date,
      "content-encoding": "gzip",
      "content-length": String(compressed.byteLength),
      "x-upstream": "retained",
      connection: "close",
    };

    upstream.on("request", (request, response) => {
      const chunks: Buffer[] = [];

      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        requests.push({
          method: request.method,
          target: request.url,
          headers: request.headers,
          body: Buffer.concat(chunks).toString(),
        });
        response.writeHead(StatusCodes.ACCEPTED, responseHeaders);
        response.end(compressed);
      });
    });

    const response = await new Promise<unknown>((resolve, reject) => {
      const request = http.request(
        { host: "127.0.0.1", port: proxy.port, path: target, method, headers },
        (reply) => {
          const chunks: Buffer[] = [];

          reply.on("data", (chunk: Buffer) => chunks.push(chunk));
          reply.on("error", reject);
          reply.on("end", () =>
            resolve({
              status: reply.statusCode,
              headers: reply.headers,
              body: Buffer.concat(chunks),
            }),
          );
        },
      );

      request.on("error", reject);
      request.end(body);
    });

    expect({ requests, response }).toStrictEqual({
      requests: [{ method, target, headers, body }],
      response: {
        status: StatusCodes.ACCEPTED,
        headers: responseHeaders,
        body: Buffer.from(compressed),
      },
    });
  },
);

async function readBytes(
  socket: Duplex,
  size: number,
  head: Buffer,
): Promise<Buffer> {
  return await new Promise<Buffer>((resolve, reject) => {
    let bytes = head;

    const data = (chunk: Buffer): void => {
      bytes = Buffer.concat([bytes, chunk]);
      finish();
    };
    const closed = (): void =>
      reject(new Error("Socket closed before the complete frame"));
    const finish = (): void => {
      if (bytes.length < size) {
        return;
      }

      socket.off("data", data);
      socket.off("error", reject);
      socket.off("close", closed);
      resolve(bytes);
    };

    socket.on("data", data);
    socket.once("error", reject);
    socket.once("close", closed);
    finish();
  });
}

it.each(["plain", "tls"])(
  "relays a WebSocket handshake and binary frames in both directions over %s HTTP",
  async (mode) => {
    const { upstream, proxy, chain, upstreamPort } = await fixture();
    const upgrades: object[] = [];
    const completed = Promise.withResolvers<void>();
    const target = "/v1/code/test/ws?session=test";
    const clientFrame = Buffer.from([0x82, 0x83, 1, 2, 3, 4, 0x41, 0x52, 0x63]);
    const serverFrame = Buffer.from([0x82, 0x03, 0x10, 0x20, 0x30]);
    const headers = {
      host: "api.anthropic.com",
      connection: "Upgrade",
      upgrade: "websocket",
      "sec-websocket-version": "13",
      "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
      authorization: "Bearer client-session-token",
    };
    const responseHeaders = {
      connection: "Upgrade",
      upgrade: "websocket",
      "sec-websocket-accept": "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    };

    upstream.on("request", (_request, response) => {
      response.writeHead(StatusCodes.UPGRADE_REQUIRED, { date });
      response.end();
    });
    upstream.on("upgrade", (request, socket, head) => {
      if (request.headers.host !== `127.0.0.1:${upstreamPort}`) {
        socket.end(
          `HTTP/1.1 ${StatusCodes.UNAUTHORIZED} Unauthorized\r\nConnection: close\r\n\r\n`,
        );

        return;
      }

      cleanup.push(async () => {
        socket.destroy();
      });
      socket.on("error", completed.reject);
      socket.write(
        Buffer.concat([
          Buffer.from(
            `HTTP/1.1 ${StatusCodes.SWITCHING_PROTOCOLS} Switching Protocols\r\n${Object.entries(
              responseHeaders,
            )
              .map(([key, value]) => `${key}: ${value}\r\n`)
              .join("")}\r\n`,
          ),
          serverFrame,
        ]),
      );

      readBytes(socket, clientFrame.length, head)
        .then((frame) => {
          upgrades.push({
            method: request.method,
            target: request.url,
            headers: request.headers,
            frame,
          });
          return completed.resolve();
        })
        .catch(completed.reject);
    });

    let secure: tls.TLSSocket | undefined;

    if (mode === "tls") {
      secure = await new Promise<tls.TLSSocket>((resolve, reject) => {
        const connect = http.request({
          host: "127.0.0.1",
          port: proxy.port,
          method: "CONNECT",
          path: "api.anthropic.com:443",
        });

        connect.on("error", reject);
        connect.on("connect", (_reply, tunnel) => {
          const socket = tls.connect(
            {
              socket: tunnel,
              servername: "api.anthropic.com",
              ca: chain.ca,
              ALPNProtocols: ["http/1.1"],
            },
            () => resolve(socket),
          );
          socket.on("error", reject);
        });
        connect.end();
      });
      const socket = secure;
      cleanup.push(async () => {
        socket.destroy();
      });
    }

    const options: http.RequestOptions = {
      host: "127.0.0.1",
      port: proxy.port,
      path: target,
      headers,
    };

    if (secure !== undefined) {
      const socket = secure;
      options.createConnection = () => socket;
    }

    const result = await new Promise<unknown>((resolve, reject) => {
      const request = http.request(options);

      request.on("error", reject);
      request.on("response", (reply) => {
        reply.resume();
        reply.on("end", () =>
          resolve({
            status: reply.statusCode,
            headers: reply.headers,
            frame: Buffer.alloc(0),
          }),
        );
      });
      request.on("upgrade", (reply, socket, head) => {
        cleanup.push(async () => {
          socket.destroy();
        });
        socket.on("error", reject);
        socket.write(clientFrame);

        Promise.all([
          readBytes(socket, serverFrame.length, head),
          completed.promise,
        ])
          .then(([frame]) => {
            return resolve({
              status: reply.statusCode,
              headers: reply.headers,
              frame,
            });
          })
          .catch(reject);
      });
      request.end();
    });

    expect({ upgrades, result }).toStrictEqual({
      upgrades: [
        {
          method: "GET",
          target,
          headers: { ...headers, host: `127.0.0.1:${upstreamPort}` },
          frame: clientFrame,
        },
      ],
      result: {
        status: StatusCodes.SWITCHING_PROTOCOLS,
        headers: responseHeaders,
        frame: serverFrame,
      },
    });
  },
);
