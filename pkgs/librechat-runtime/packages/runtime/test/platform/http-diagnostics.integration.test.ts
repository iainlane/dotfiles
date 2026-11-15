import { once } from "node:events";
import { configureSync, getLogger, resetSync } from "@logtape/logtape";
import { afterEach, expect, it } from "vitest";
import { z } from "zod";
import { httpService } from "#runtime/http/http-server";
import { errorDiagnostic } from "#runtime/platform/diagnostics";
import { diagnosticSink } from "#runtime/platform/logging";

const timestamp: unknown = expect.stringMatching(
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u,
);

afterEach(() => {
  resetSync();
});

it("keeps HTTP failures generic while reporting the redacted transport cause to the operator", async () => {
  const output: string[] = [];
  configureSync({
    sinks: { output: diagnosticSink({ write: (text) => output.push(text) }) },
    loggers: [
      { category: ["librechat"], lowestLevel: "error", sinks: ["output"] },
    ],
  });
  const logger = getLogger(["librechat"]);
  const socket = Object.assign(new Error("other side closed"), {
    code: "UND_ERR_SOCKET",
    stack: undefined,
  });
  const failure = Object.assign(
    new TypeError("fetch failed (Bearer fixture-private-token)", {
      cause: socket,
    }),
    {
      stack: undefined,
      headers: { authorization: "fixture-private-token" },
      body: "private-request-body",
    },
  );
  const server = httpService({
    handler: async () => {
      throw failure;
    },
    onError: (error) => {
      logger.error("Host service operation failed", {
        event: "librechat-service-error",
        error: errorDiagnostic(error),
      });
    },
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = z.object({ port: z.number() }).parse(server.address());
  try {
    const response = await fetch(
      `http://127.0.0.1:${port}/runner/api/v2/execute`,
      {
        method: "POST",
        headers: { authorization: "Bearer fixture-private-token" },
        body: "private-request-body",
        signal: AbortSignal.timeout(2000),
      },
    );
    const body: unknown = await response.json();
    const reports = output.map((line): unknown => JSON.parse(line));
    expect({ status: response.status, body, reports }).toStrictEqual({
      status: 500,
      body: { error: "TypeError" },
      reports: [
        {
          "@timestamp": timestamp,
          level: "ERROR",
          logger: "librechat",
          message: "Host service operation failed",
          event: "librechat-service-error",
          error: {
            name: "TypeError",
            message: "fetch failed (Bearer [redacted])",
            cause: {
              name: "Error",
              message: "other side closed",
              code: "UND_ERR_SOCKET",
            },
          },
        },
      ],
    });
  } finally {
    server.closeAllConnections();
    await new Promise<void>((done) => {
      server.close(() => done());
    });
  }
});
