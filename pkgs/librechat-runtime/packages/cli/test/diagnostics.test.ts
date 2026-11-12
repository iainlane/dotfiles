import { expect, it } from "vitest";
import { GuestOperationError } from "#cli/application/errors";
import { ErrorReporter } from "#cli/presentation/errors";
import { testLogger } from "./logging.ts";

it("keeps ordinary command errors concise without exposing their causes", () => {
  const output: string[] = [];
  const reporter = new ErrorReporter({
    diagnostics: false,
    logger: testLogger((text) => output.push(text)),
    secrets: [],
    write: (text) => {
      output.push(text);
    },
  });
  reporter.report(new GuestOperationError(new Error("private detail")));
  expect(output).toStrictEqual([
    "Error: The LibreChat guest operation failed. Check the guest service logs.\n",
  ]);
});

it("reports the underlying transport cause when service diagnostics are enabled", () => {
  const output: string[] = [];
  const reporter = new ErrorReporter({
    diagnostics: true,
    logger: testLogger((text) => output.push(text)),
    secrets: [],
    write: (text) => {
      output.push(text);
    },
  });
  const socket = Object.assign(new Error("other side closed"), {
    code: "UND_ERR_SOCKET",
    stack: undefined,
  });
  const fetch = Object.assign(
    new TypeError("fetch failed", { cause: socket }),
    { stack: undefined },
  );
  const error = Object.assign(new GuestOperationError(fetch), {
    stack: undefined,
  });
  reporter.report(error);
  expect(
    output.map((line, index): unknown =>
      index === 0 ? line : JSON.parse(line),
    ),
  ).toStrictEqual([
    "Error: The LibreChat guest operation failed. Check the guest service logs.\n",
    {
      "@timestamp": "1970-01-01T00:00:00.000Z",
      level: "ERROR",
      logger: "librechat",
      message: "LibreChat operation failed",
      entryPoint: "runtime",
      event: "librechat-service-error",
      error: {
        name: "GuestOperationError",
        message:
          "The LibreChat guest operation failed. Check the guest service logs.",
        cause: {
          name: "TypeError",
          message: "fetch failed",
          cause: {
            name: "Error",
            message: "other side closed",
            code: "UND_ERR_SOCKET",
          },
        },
      },
    },
  ]);
});
