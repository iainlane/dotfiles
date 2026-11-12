import { redactByPattern } from "@logtape/redaction";
import { diagnosticPatterns } from "#runtime/platform/redaction";

interface ErrorDiagnostic {
  name: string;
  message: string;
  code?: string | number;
  stack?: string;
  cause?: ErrorDiagnostic;
  errors?: ErrorDiagnostic[];
}

export function redactDiagnostic(
  text: string,
  secrets: readonly string[] = [],
): string {
  return redactByPattern(
    () => text,
    diagnosticPatterns(secrets),
  )({
    category: ["librechat"],
    level: "debug",
    timestamp: 0,
    rawMessage: text,
    message: [text],
    properties: {},
  });
}

export function errorDiagnostic(
  error: unknown,
  secrets: readonly string[] = [],
): ErrorDiagnostic {
  const seen = new Set<Error>();
  let remaining = 32;
  const text = (value: string): string =>
    redactDiagnostic(value, secrets).slice(0, 8192);
  const visit = (value: unknown, depth: number): ErrorDiagnostic => {
    if (!(value instanceof Error)) {
      return { name: "NonError", message: "A non-error value was thrown." };
    }
    if (depth >= 8 || remaining <= 0 || seen.has(value)) {
      return {
        name: "OmittedCause",
        message: "The error cause limit was reached.",
      };
    }
    remaining -= 1;
    seen.add(value);
    const code = "code" in value ? value.code : undefined;
    return {
      name: text(value.name),
      message: text(value.message),
      ...(typeof code === "string" ? { code: text(code) } : {}),
      ...(typeof code === "number" ? { code } : {}),
      ...(value.stack === undefined ? {} : { stack: text(value.stack) }),
      ...(value.cause === undefined
        ? {}
        : { cause: visit(value.cause, depth + 1) }),
      ...(value instanceof AggregateError
        ? {
            errors: value.errors
              .slice(0, 8)
              .map((cause: unknown) => visit(cause, depth + 1)),
          }
        : {}),
    };
  };
  return visit(error, 0);
}
