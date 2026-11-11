interface ErrorDiagnostic {
  name: string;
  message: string;
  code?: string | number;
  stack?: string;
  cause?: ErrorDiagnostic;
  errors?: ErrorDiagnostic[];
}

interface RedactionRange {
  start: number;
  end: number;
  replacement: string;
}

function sanitizedUrl(value: string): string {
  try {
    const url = new URL(value);
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return url.href;
  } catch {
    return "[redacted URL]";
  }
}

export function redactDiagnostic(
  text: string,
  secrets: readonly string[] = [],
): string {
  const ranges: RedactionRange[] = [];
  for (const secret of secrets.filter((value) => value.length > 0)) {
    let offset = text.indexOf(secret);
    while (offset !== -1) {
      ranges.push({
        start: offset,
        end: offset + secret.length,
        replacement: "[redacted]",
      });
      offset = text.indexOf(secret, offset + 1);
    }
  }
  const collect = (
    pattern: RegExp,
    replacement: (value: string) => string,
  ): void => {
    for (const match of text.matchAll(pattern)) {
      const prefix = match[1] ?? "";
      ranges.push({
        start: match.index + prefix.length,
        end: match.index + match[0].length,
        replacement: replacement(match[0]),
      });
    }
  };
  collect(
    /\b(authorization["']?\s*[:=]\s*)(?:"(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\(?:[\s\S]|$)|[^'\\])*(?:'|$)|[^\r\n,;}]+)/giu,
    () => "[redacted]",
  );
  collect(
    /\b((?:Bearer|Basic|token)\s+)[A-Za-z0-9+/_=.-]+/giu,
    () => "[redacted]",
  );
  collect(
    /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/gu,
    () => "[redacted]",
  );
  collect(
    /-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)/gu,
    () => "[redacted private key]",
  );
  collect(
    /\b(?:https?|mongodb(?:\+srv)?|rediss?|postgres(?:ql)?):\/\/[^\s"'<>]+/giu,
    sanitizedUrl,
  );
  collect(
    /\b([a-z0-9_-]*(?:authorization|token|password|secret|api[_-]?key|private[_-]?key)["']?\s*[:=]\s*)(?:"(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\(?:[\s\S]|$)|[^'\\])*(?:'|$)|[^\s,;]+)/giu,
    () => "[redacted]",
  );

  let result = "";
  let position = 0;
  let pending: RedactionRange | undefined;
  for (const range of ranges.toSorted(
    (left, right) => left.start - right.start,
  )) {
    if (pending !== undefined && range.start < pending.end) {
      pending.end = Math.max(pending.end, range.end);
      pending.replacement = "[redacted]";
      continue;
    }
    if (pending !== undefined) {
      result += text.slice(position, pending.start) + pending.replacement;
      position = pending.end;
    }
    pending = { ...range };
  }
  if (pending !== undefined) {
    result += text.slice(position, pending.start) + pending.replacement;
    position = pending.end;
  }
  return result + text.slice(position);
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
