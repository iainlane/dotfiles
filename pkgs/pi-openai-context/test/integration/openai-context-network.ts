import type { CatalogueResponse } from "./openai-context-scenarios.ts";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import {
  createServer as createProxy,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import { createServer as createHttps } from "node:https";
import { connect, type Server, type Socket } from "node:net";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import { parseRecord } from "@dotfiles/pi-integration-tests/protocol";

interface ObservedRequest {
  host: string | undefined;
  path: string | undefined;
  authorization: string | undefined;
}

interface OpenAINetwork {
  env: NodeJS.ProcessEnv;
  requests: readonly ObservedRequest[];
  advertiseAccountWindow: (contextWindow: number) => void;
}

interface NetworkOptions {
  agentDir: string;
  models: readonly string[];
  catalogue: CatalogueResponse | undefined;
}

function responsesStream(model: string): string {
  const content = [
    { type: "output_text", text: "Fixture response", annotations: [] },
  ];
  const item = {
    id: "msg_fixture",
    type: "message",
    role: "assistant",
    content,
  };
  const events = [
    {
      type: "response.output_item.added",
      output_index: 0,
      item: { ...item, content: [] },
    },
    {
      type: "response.output_text.delta",
      output_index: 0,
      delta: "Fixture response",
    },
    { type: "response.output_item.done", output_index: 0, item },
    {
      type: "response.completed",
      response: {
        id: "resp_fixture",
        status: "completed",
        model,
        output: [item],
        usage: { input_tokens: 40, output_tokens: 3, total_tokens: 43 },
      },
    },
  ];
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
}

async function replyToResponses(
  request: IncomingMessage,
  response: ServerResponse,
): Promise<void> {
  try {
    request.setEncoding("utf8");
    let payload = "";
    for await (const chunk of request) {
      const text: unknown = chunk;
      assert.ok(typeof text === "string");
      payload += text;
    }
    const { model } = parseRecord(payload);
    assert.ok(typeof model === "string");
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(responsesStream(model));
  } catch {
    response.writeHead(400).end();
  }
}

async function replyToCatalogue(
  response: ServerResponse,
  options: NetworkOptions,
  accountWindow: number,
): Promise<void> {
  switch (options.catalogue) {
    case "failure":
      response.writeHead(503).end();
      return;
    case "malformed":
      response.writeHead(200, { "content-type": "application/json" }).end("{");
      return;
    case "timeout":
      return;
    case "redirect":
      response.writeHead(302, { location: "/v1/unexpected-redirect" }).end();
      return;
    case "delayed":
      await setTimeout(250);
      break;
    case undefined:
    case "empty":
    case "small":
      break;
  }

  const models =
    options.catalogue === "empty"
      ? []
      : [
          ...options.models.map((slug) => ({
            slug,
            context_window: options.catalogue === "small" ? 1 : accountWindow,
            max_context_window: 872_000,
          })),
          { slug: "unknown-model", context_window: 700_000 },
        ];
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ models }));
}

async function listen(server: Server): Promise<number> {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address !== null && typeof address !== "string");
  return address.port;
}

export async function withOpenAIContextNetwork<T>(
  options: NetworkOptions,
  run: (network: OpenAINetwork) => Promise<T>,
): Promise<T> {
  const certificate = join(options.agentDir, "fixture-cert.pem");
  const key = join(options.agentDir, "fixture-key.pem");
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      key,
      "-out",
      certificate,
      "-days",
      "1",
      "-subj",
      "/CN=api.openai.com",
      "-addext",
      "subjectAltName=DNS:api.openai.com,DNS:auth.openai.com",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );

  const requests: ObservedRequest[] = [];
  let accountWindow = 510_000;
  const tls = { cert: await readFile(certificate), key: await readFile(key) };
  const upstream = createHttps(tls, (request, response) => {
    const host = request.headers.host;
    const path = request.url?.split("?", 1)[0];
    requests.push({
      host,
      path,
      authorization: request.headers.authorization,
    });

    if (
      host === "api.openai.com" &&
      path === "/v1/models" &&
      request.method === "GET"
    ) {
      void replyToCatalogue(response, options, accountWindow);
      return;
    }
    if (
      host === "api.openai.com" &&
      path === "/v1/responses" &&
      request.method === "POST"
    ) {
      void replyToResponses(request, response);
      return;
    }
    if (
      host === "auth.openai.com" &&
      path === "/api/accounts/oauth/token" &&
      request.method === "POST"
    ) {
      request.resume();
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          access_token: "rotated",
          refresh_token: "renewed",
          expires_in: 3600,
          scope: "chatgpt.tokens.use.direct",
        }),
      );
      return;
    }
    response.writeHead(404).end();
  });
  const proxy = createProxy((_request, response) =>
    response.writeHead(502).end(),
  );
  const sockets = new Set<Socket>();
  proxy.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("error", () => socket.destroy());
    socket.once("close", () => sockets.delete(socket));
  });

  try {
    const port = await listen(upstream);
    proxy.on("connect", (request, client, head) => {
      if (
        request.url !== "api.openai.com:443" &&
        request.url !== "auth.openai.com:443"
      ) {
        client.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        return;
      }
      const target = connect(port, "127.0.0.1");
      target.on("error", () => client.destroy());
      client.on("error", () => target.destroy());
      client.on("close", () => target.destroy());
      target.on("connect", () => {
        client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        if (head.length > 0) {
          target.write(head);
        }
        client.pipe(target).pipe(client);
      });
    });

    const proxyUrl = `http://127.0.0.1:${await listen(proxy)}`;
    return await run({
      env: {
        ...process.env,
        HTTP_PROXY: proxyUrl,
        HTTPS_PROXY: proxyUrl,
        http_proxy: proxyUrl,
        https_proxy: proxyUrl,
        NO_PROXY: "",
        no_proxy: "",
        NODE_EXTRA_CA_CERTS: certificate,
      },
      requests,
      advertiseAccountWindow: (window) => {
        accountWindow = window;
      },
    });
  } finally {
    proxy.close();
    for (const socket of sockets) {
      socket.destroy();
    }
    upstream.closeAllConnections();
    upstream.close();
  }
}
