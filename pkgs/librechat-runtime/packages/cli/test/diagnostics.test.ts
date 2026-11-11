import { expect, it } from "vitest";
import { GuestOperationError } from "#cli/application/errors";
import { ErrorReporter } from "#cli/presentation/errors";

it("keeps ordinary command errors concise without exposing their causes", () => {
  const output: string[] = [];
  const reporter = new ErrorReporter({
    diagnostics: false,
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
  expect(output).toStrictEqual([
    "Error: The LibreChat guest operation failed. Check the guest service logs.\n",
    JSON.stringify({
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
    }) + "\n",
  ]);
});
