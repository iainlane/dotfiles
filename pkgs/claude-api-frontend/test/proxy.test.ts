import http from "node:http";
import http2 from "node:http2";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import tls from "node:tls";
import { afterEach, expect, it } from "vitest";
import { certificates } from "../src/certificates.ts";
import { startProxy } from "../src/proxy.ts";
import { StatusCodes } from "http-status-codes";
import { FakeTransport } from "./fakes.ts";
import { UpstreamError } from "../src/errors.ts";
import type { Transport } from "../src/transport.ts";
import { configSchema } from "../src/config.ts";

const anyString: unknown = expect.any(String);
const anyBuffer: unknown = expect.any(Buffer);

const cleanup: (() => Promise<unknown>)[] = [];
afterEach(async () => {
  await cleanup.toReversed().reduce(async (previous, close) => {
    await previous;
    await close();
  }, Promise.resolve());
  cleanup.length = 0;
});

async function fixture(transport?: Transport) {
  const directory = await mkdtemp(join(tmpdir(), "claude-api-frontend-test-"));
  cleanup.push(() => rm(directory, { recursive: true, force: true }));
  const chain = await certificates(directory);
  const upstream = http.createServer();
  await new Promise<void>((resolve) => {
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
    stateDirectory: directory,
    teamclaudeConfigFile: "/unused",
    account: "api account",
    maxBodyBytes: 512,
  });
  const proxy = await startProxy(
    { ...config, port: 0 },
    address.port,
    chain,
    transport,
  );
  cleanup.push(() => proxy.close());
  return {
    directory,
    chain,
    upstream,
    proxy,
    config: { ...config, port: proxy.port },
    upstreamPort: address.port,
  };
}

it("persists a private CA across restarts", async () => {
  const { directory, chain } = await fixture();
  const next = await certificates(directory);
  expect({
    certificates: next,
    mode: (await stat(join(directory, "authority", "ca.key"))).mode & 0o777,
    directoryMode: (await stat(directory)).mode & 0o777,
  }).toStrictEqual({
    certificates: { key: anyBuffer, cert: anyBuffer, ca: chain.ca },
    mode: 0o600,
    directoryMode: 0o700,
  });
  expect(await readFile(join(directory, "authority", "ca.pem"))).toStrictEqual(
    chain.ca,
  );
});

it.each(["http/1.1", "h2"])(
  "converts inference over CONNECT with %s and streams the response",
  async (protocol) => {
    const { chain, upstream, proxy, upstreamPort, directory } = await fixture();

    proxy.reloadCertificates(await certificates(directory));
    const received = new Promise<unknown>((resolve) => {
      upstream.on("request", (request, response) => {
        const chunks: Buffer[] = [];
        request.on("data", (chunk: Buffer) => chunks.push(chunk));
        request.on("end", () => {
          resolve({
            url: request.url,
            method: request.method,
            headers: request.headers,
            body: Buffer.concat(chunks).toString(),
          });
          response.writeHead(StatusCodes.OK, {
            "content-type": "text/event-stream",
          });
          response.write("data: first\n\n");
        });
      });
    });
    const socket = await new Promise<tls.TLSSocket>((resolve, reject) => {
      const connect = http.request({
        host: "127.0.0.1",
        port: proxy.port,
        method: "CONNECT",
        path: "api.anthropic.com:443",
      });
      connect.on("error", reject);
      connect.on("connect", (_response, tunnel) => {
        const secure = tls.connect(
          {
            socket: tunnel,
            servername: "api.anthropic.com",
            ca: chain.ca,
            ALPNProtocols: [protocol],
          },
          () => resolve(secure),
        );
        secure.on("error", reject);
      });
      connect.end();
    });
    const body = JSON.stringify({
      system: "x-anthropic-billing-header: test\nKeep.",
      messages: [],
    });
    const headers = {
      "user-agent": "claude-cli/2.1.310 (external, cli)",
      "anthropic-beta": "claude-code-20250219,other-beta",
      "content-length": String(Buffer.byteLength(body)),
    };
    const firstChunk = new Promise<string>((resolve, reject) => {
      if (protocol === "h2") {
        const client = http2.connect("https://api.anthropic.com", {
          createConnection: () => socket,
        });
        cleanup.push(async () => {
          client.destroy();
        });
        const stream = client.request({
          ...headers,
          ":path": "/v1/messages?beta=true",
          ":method": "POST",
        });
        stream.once("data", (chunk: Buffer) => resolve(chunk.toString()));
        stream.on("error", reject);
        stream.end(body);
        return;
      }
      const request = http.request(
        {
          host: "api.anthropic.com",
          method: "POST",
          path: "/v1/messages?beta=true",
          headers,
          createConnection: () => socket,
        },
        (response) => {
          response.once("data", (chunk: Buffer) => resolve(chunk.toString()));
        },
      );
      request.on("error", reject);
      request.end(body);
    });
    cleanup.push(async () => {
      socket.destroy();
    });
    expect(await firstChunk).toBe("data: first\n\n");
    const converted = JSON.stringify({ system: "Keep.", messages: [] });
    expect(await received).toStrictEqual({
      url: "/tc-acct/api%20account/v1/messages?beta=true",
      method: "POST",
      headers: {
        host: `127.0.0.1:${upstreamPort}`,
        connection: "keep-alive",
        "user-agent": "claude-cli/2.1.310 (external, sdk-cli)",
        "anthropic-beta": "other-beta",
        "content-length": String(Buffer.byteLength(converted)),
        accept: "*/*",
        "accept-language": "*",
        "sec-fetch-mode": "cors",
        "accept-encoding": "gzip, deflate",
      },
      body: converted,
    });
  },
);

it.each([
  {
    path: "/v1/messages",
    headers: {},
    body: "x".repeat(513),
    status: StatusCodes.REQUEST_TOO_LONG,
    error: { code: "request-too-large", maxBodyBytes: 512 },
  },
  {
    path: "/v1/messages",
    headers: { "content-encoding": "gzip" },
    body: "compressed",
    status: StatusCodes.UNSUPPORTED_MEDIA_TYPE,
    error: { code: "unsupported-encoding", encoding: "gzip" },
  },
  {
    path: "ftp://other.example/v1/messages",
    headers: {},
    body: "{}",
    status: StatusCodes.BAD_REQUEST,
    error: { code: "invalid-request-target" },
  },
])(
  "rejects unsupported inference requests before forwarding: $status",
  async ({ path, headers, body, status, error }) => {
    const transport = new FakeTransport(() => new Response());
    const { proxy } = await fixture(transport);
    const result = await new Promise<unknown>((resolve, reject) => {
      const request = http.request(
        { host: "127.0.0.1", port: proxy.port, path, method: "POST", headers },
        (response) => {
          const chunks: Buffer[] = [];

          response.on("data", (chunk: Buffer) => chunks.push(chunk));
          response.on("end", () => {
            const decoded: unknown = JSON.parse(
              Buffer.concat(chunks).toString(),
            );

            resolve({
              status: response.statusCode,
              headers: response.headers,
              body: decoded,
            });
          });
        },
      );
      request.on("error", reject);
      request.end(body);
    });
    expect({
      response: result,
      requests: await transport.snapshot(),
    }).toStrictEqual({
      response: {
        status,
        headers: {
          "cache-control": "no-store",
          "content-type": "application/json",
          "content-length": anyString,
          connection: "keep-alive",
          "keep-alive": "timeout=5",
          date: anyString,
        },
        body: {
          error: {
            ...error,
            status,
            type: "frontend_error",
            message: anyString,
          },
        },
      },
      requests: [],
    });
  },
);

it("preserves non-inference requests through the injected transport", async () => {
  const transport = new FakeTransport(
    () =>
      new Response("upstream response", {
        status: StatusCodes.ACCEPTED,
        headers: { "x-upstream": "retained" },
      }),
  );
  const { proxy, upstreamPort } = await fixture(transport);
  const input = '{ "system": "x-anthropic-billing-header: preserve" }';
  const response = await fetch(
    `http://127.0.0.1:${proxy.port}/v1/messages/count_tokens`,
    {
      method: "POST",
      headers: {
        "user-agent": "claude-cli/2.1.310 (external, cli)",
        "anthropic-beta": "claude-code-20250219,other-beta",
      },
      body: input,
    },
  );
  const requests = await Promise.all(
    transport.requests.map(async (request) => ({
      url: request.url,
      method: request.method,
      headers: Object.fromEntries(request.headers),
      body: await request.text(),
    })),
  );

  expect({
    requests,
    response: await response.text(),
    status: response.status,
    headers: Object.fromEntries(response.headers),
  }).toStrictEqual({
    requests: [
      {
        url: `http://127.0.0.1:${upstreamPort}/v1/messages/count_tokens`,
        method: "POST",
        headers: {
          accept: "*/*",
          "accept-encoding": "gzip, deflate",
          "accept-language": "*",
          "anthropic-beta": "claude-code-20250219,other-beta",
          "content-length": String(Buffer.byteLength(input)),
          "content-type": "text/plain;charset=UTF-8",
          "sec-fetch-mode": "cors",
          "user-agent": "claude-cli/2.1.310 (external, cli)",
        },
        body: input,
      },
    ],
    response: "upstream response",
    status: StatusCodes.ACCEPTED,
    headers: {
      connection: "keep-alive",
      "content-type": "text/plain;charset=UTF-8",
      date: anyString,
      "keep-alive": "timeout=5",
      "transfer-encoding": "chunked",
      "x-upstream": "retained",
    },
  });
});

it("cancels the upstream stream when the client disconnects", async () => {
  let aborted: (() => void) | undefined;
  const cancelled = new Promise<void>((resolve) => {
    aborted = resolve;
  });
  const transport = new FakeTransport((request) => {
    request.signal.addEventListener("abort", () => aborted?.(), { once: true });

    return new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode("data: first\n\n"));
        },
      }),
    );
  });
  const { proxy } = await fixture(transport);
  const controller = new AbortController();
  const response = await fetch(`http://127.0.0.1:${proxy.port}/v1/messages`, {
    method: "POST",
    body: "{}",
    signal: controller.signal,
  });
  const reader = response.body?.getReader();

  expect(await reader?.read()).toStrictEqual({
    done: false,
    value: new TextEncoder().encode("data: first\n\n"),
  });
  controller.abort();

  await cancelled;
});

it("returns a typed upstream error without exposing the cause", async () => {
  const transport = new FakeTransport(() => {
    throw new UpstreamError({ cause: { credential: "private" } });
  });
  const { proxy } = await fixture(transport);
  const response = await fetch(`http://127.0.0.1:${proxy.port}/v1/messages`, {
    method: "POST",
    body: "{}",
  });
  const body: unknown = await response.json();

  expect({
    status: response.status,
    headers: Object.fromEntries(response.headers),
    body,
  }).toStrictEqual({
    status: StatusCodes.BAD_GATEWAY,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
      "content-length": anyString,
      connection: "keep-alive",
      "keep-alive": "timeout=5",
      date: anyString,
    },
    body: {
      error: {
        type: "frontend_error",
        code: "upstream",
        status: StatusCodes.BAD_GATEWAY,
        message: anyString,
      },
    },
  });
});

it("chains other CONNECT tunnels through TeamClaude", async () => {
  const { proxy, upstream } = await fixture();
  const connected = new Promise<string | undefined>((resolve) => {
    upstream.on("connect", (request, socket, head) => {
      resolve(request.url);
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");

      if (head.length > 0) {
        socket.write(head);
      }

      socket.pipe(socket);
    });
  });
  const echoed = await new Promise<string>((resolve, reject) => {
    const request = http.request({
      host: "127.0.0.1",
      port: proxy.port,
      method: "CONNECT",
      path: "other.example:443",
    });

    request.on("error", reject);
    request.on("connect", (_reply, socket) => {
      cleanup.push(async () => {
        socket.destroy();
      });
      socket.once("data", (chunk: Buffer) => resolve(chunk.toString()));
      socket.on("error", reject);
      socket.write("tunnel bytes");
    });
    request.end();
  });

  expect({ target: await connected, echoed }).toStrictEqual({
    target: "other.example:443",
    echoed: "tunnel bytes",
  });
});
