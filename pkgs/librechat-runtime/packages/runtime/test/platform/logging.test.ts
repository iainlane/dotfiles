import { inspect, stripVTControlCharacters } from "node:util";
import { configureSync, getLogger, resetSync } from "@logtape/logtape";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { diagnosticSink } from "#runtime/platform/logging";
import { errorDiagnostic } from "#runtime/platform/diagnostics";

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(0);
});

afterEach(() => {
  resetSync();
  vi.useRealTimers();
});

/**
 * Splits a terminal record into its header line and the inspected properties
 * that follow it. LogTape renders the timestamp and level in the header.
 */
function terminalRecord(line: string): { header: string; properties: string } {
  const plain = stripVTControlCharacters(line);
  const end = plain.indexOf("\n");
  return { header: plain.slice(0, end), properties: plain.slice(end + 1) };
}

/** Matches a terminal header with our layout for the category and message. */
function terminalHeader(category: string, message: string): unknown {
  return expect.stringMatching(
    new RegExp(`^.+ \\[.+\\] ${category}: ${message}$`, "u"),
  );
}

function inspected(properties: unknown): string {
  return `${stripVTControlCharacters(inspect(properties, { colors: true, depth: 8 }))}\n`;
}

it("redacts structured fields and text without losing error causes or child context", () => {
  const output: string[] = [];
  configureSync({
    sinks: {
      output: diagnosticSink({
        write: (text) => output.push(text),
        secrets: ['fixture-"private\\value'],
      }),
    },
    loggers: [
      { category: ["librechat"], lowestLevel: "debug", sinks: ["output"] },
      {
        category: ["logtape", "meta"],
        lowestLevel: "warning",
        sinks: ["output"],
      },
    ],
  });
  const logger = getLogger(["librechat"]).with({ service: "host" });
  const guest = logger.with({ runtimeId: "rt_fixture" });
  const cause = Object.assign(new Error("other side closed"), {
    stack: undefined,
    code: "UND_ERR_SOCKET",
  });
  const error = Object.assign(new TypeError("fetch failed", { cause }), {
    stack: "TypeError: fetch failed\n    at forward (/fixture/main.ts:1:1)",
    request: { body: "do-not-log" },
  });
  guest.error("Guest operation failed", {
    event: "guest-failure",
    error: errorDiagnostic(error),
    detail: 'using fixture-"private\\value',
    headers: { authorization: "Bearer private", "set-cookie": ["sid=private"] },
  });
  logger.info("Host ready", { event: "host-ready" });
  expect(output.map((line): unknown => JSON.parse(line))).toStrictEqual([
    {
      "@timestamp": "1970-01-01T00:00:00.000Z",
      level: "ERROR",
      logger: "librechat",
      message: "Guest operation failed",
      service: "host",
      runtimeId: "rt_fixture",
      event: "guest-failure",
      detail: "using [redacted]",
      headers: { authorization: "[redacted]", "set-cookie": "[redacted]" },
      error: {
        name: "TypeError",
        message: "fetch failed",
        stack: "TypeError: fetch failed\n    at forward (/fixture/main.ts:1:1)",
        cause: {
          name: "Error",
          message: "other side closed",
          code: "UND_ERR_SOCKET",
        },
      },
    },
    {
      "@timestamp": "1970-01-01T00:00:00.000Z",
      level: "INFO",
      logger: "librechat",
      message: "Host ready",
      service: "host",
      event: "host-ready",
    },
  ]);
});

it.each([
  {
    terminal: false,
    field: "set-cookie",
    replacement: "[redacted cookie array]",
  },
  {
    terminal: true,
    field: "set-cookie",
    replacement: "[redacted cookie array]",
  },
  {
    terminal: false,
    field: "token",
    replacement: "[redacted credential array]",
  },
  {
    terminal: true,
    field: "token",
    replacement: "[redacted credential array]",
  },
])(
  "omits printed $field arrays before writing terminal=$terminal diagnostics",
  ({ terminal, field, replacement }) => {
    const output: string[] = [];
    configureSync({
      sinks: {
        output: diagnosticSink({
          write: (text) => output.push(text),
          terminal,
        }),
      },
      loggers: [
        { category: ["librechat"], lowestLevel: "info", sinks: ["output"] },
        {
          category: ["logtape", "meta"],
          lowestLevel: "warning",
          sinks: ["output"],
        },
      ],
    });
    const message = `{${JSON.stringify(field)}: [\n  "fixture-private-token",\n  "another-private-value"\n]}`;
    const cause = Object.assign(new Error("socket closed"), {
      stack: undefined,
    });
    const error = Object.assign(new Error(message, { cause }), {
      code: "UND_ERR_SOCKET",
      stack: `Error: ${message}\n    at request (/fixture/main.ts:1:1)`,
    });
    getLogger(["librechat"])
      .with({ service: "guest" })
      .error("Request failed", {
        event: "request-failure",
        error: errorDiagnostic(error),
      });
    const properties = {
      service: "guest",
      event: "request-failure",
      error: {
        name: "Error",
        message: replacement,
        code: "UND_ERR_SOCKET",
        stack: replacement,
        cause: { name: "Error", message: "socket closed" },
      },
    };
    expect(
      terminal
        ? output.map((line) => terminalRecord(line))
        : output.map((line): unknown => JSON.parse(line)),
    ).toStrictEqual([
      terminal
        ? {
            header: terminalHeader("librechat", "Request failed"),
            properties: inspected(properties),
          }
        : {
            "@timestamp": "1970-01-01T00:00:00.000Z",
            level: "ERROR",
            message: "Request failed",
            logger: "librechat",
            ...properties,
          },
    ]);
  },
);

it("uses readable terminal output with redacted structured context", () => {
  const output: string[] = [];
  configureSync({
    sinks: {
      output: diagnosticSink({
        write: (text) => output.push(text),
        terminal: true,
      }),
    },
    loggers: [
      { category: ["librechat"], lowestLevel: "info", sinks: ["output"] },
      {
        category: ["logtape", "meta"],
        lowestLevel: "warning",
        sinks: ["output"],
      },
    ],
  });
  getLogger(["librechat"]).with({ service: "guest" }).error("Runner failed", {
    event: "runner-failure",
    password: "private-value",
    code: "ENOENT",
  });
  expect(output.map((line) => terminalRecord(line))).toStrictEqual([
    {
      header: terminalHeader("librechat", "Runner failed"),
      properties: inspected({
        service: "guest",
        event: "runner-failure",
        password: "[redacted]",
        code: "ENOENT",
      }),
    },
  ]);
});
