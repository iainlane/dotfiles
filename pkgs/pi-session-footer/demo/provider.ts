import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import { setTimeout as delay } from "node:timers/promises";
import { record } from "#footer/shared/text.ts";
import type { DemoFixture } from "./fixture.ts";

interface CompletionDelta {
  role?: "assistant";
  content?: string;
}
interface CompletionFrame {
  id: string;
  object: "chat.completion.chunk";
  model: string;
  choices: {
    index: number;
    delta: CompletionDelta;
    finish_reason: "stop" | null;
  }[];
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
    prompt_tokens_details: { cached_tokens: number };
  };
}

const REQUEST_LIMIT = 1_048_576;

class MissingDemoPortError extends Error {
  constructor() {
    super("Expected the demo server's loopback port");
    this.name = "MissingDemoPortError";
  }
}

class TextRequestChunkError extends Error {
  constructor() {
    super("Expected request bytes");
    this.name = "TextRequestChunkError";
  }
}

class DemoRequestTooLargeError extends Error {
  readonly limit = REQUEST_LIMIT;

  constructor() {
    super(`Demo request exceeds ${REQUEST_LIMIT} bytes`);
    this.name = "DemoRequestTooLargeError";
  }
}

export class DemoProvider {
  private readonly server: Server;
  private readonly fixture: DemoFixture;
  private readonly shutdown = new AbortController();

  private constructor(fixture: DemoFixture) {
    this.fixture = fixture;
    this.server = createServer((request, response) => {
      void this.handle(request, response);
    });
  }

  static async start(fixture: DemoFixture): Promise<DemoProvider> {
    const provider = new DemoProvider(fixture);
    await new Promise<void>((resolve, reject) => {
      provider.server.once("error", reject);
      provider.server.listen(0, "127.0.0.1", () => {
        provider.server.off("error", reject);
        resolve();
      });
    });
    return provider;
  }

  get url(): string {
    const address = this.server.address();
    if (address === null || typeof address === "string") {
      throw new MissingDemoPortError();
    }
    return `http://127.0.0.1:${address.port}/v1`;
  }

  private async body(request: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of request) {
      if (!Buffer.isBuffer(chunk)) {
        throw new TextRequestChunkError();
      }
      size += chunk.length;
      if (size > REQUEST_LIMIT) {
        throw new DemoRequestTooLargeError();
      }
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString());
  }

  private frame(
    delta: CompletionDelta,
    finishReason: "stop" | null,
  ): CompletionFrame {
    return {
      id: "footer-demo",
      object: "chat.completion.chunk",
      model: this.fixture.model.id,
      choices: [{ index: 0, delta, finish_reason: finishReason }],
    };
  }

  private event(response: ServerResponse, value: CompletionFrame): void {
    if (!response.destroyed) {
      response.write(`data: ${JSON.stringify(value)}\n\n`);
    }
  }

  private async handle(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    try {
      await this.respond(request, response);
    } catch {
      if (response.headersSent) {
        response.destroy();
        return;
      }
      response.writeHead(400);
      response.end("Expected a bounded JSON request");
    }
  }

  private async respond(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
      response.writeHead(404);
      response.end("Unknown demo endpoint");
      return;
    }
    const body = await this.body(request);
    if (!record(body) || body.model !== this.fixture.model.id) {
      response.writeHead(400);
      response.end(`Expected the ${this.fixture.model.id} model`);
      return;
    }
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    response.flushHeaders();
    await Promise.all(
      this.fixture.response.map(async ({ atMs, text }, index) => {
        await delay(atMs, undefined, { signal: this.shutdown.signal });
        const delta: CompletionDelta =
          index === 0
            ? { role: "assistant", content: text }
            : { content: text };
        this.event(response, this.frame(delta, null));
      }),
    );
    const { promptTokens, cachedTokens, outputTokens } = this.fixture.usage;
    this.event(response, {
      ...this.frame({}, "stop"),
      usage: {
        prompt_tokens: promptTokens,
        completion_tokens: outputTokens,
        total_tokens: promptTokens + outputTokens,
        prompt_tokens_details: { cached_tokens: cachedTokens },
      },
    });
    if (!response.destroyed) {
      response.end("data: [DONE]\n\n");
    }
  }

  close(): Promise<void> {
    this.shutdown.abort();
    return new Promise((resolve, reject) => {
      this.server.close((error) => {
        if (error !== undefined) {
          reject(error);
          return;
        }
        resolve();
      });
      this.server.closeAllConnections();
    });
  }
}
