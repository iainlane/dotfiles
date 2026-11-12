import { JWT_PATTERN, type RedactionPattern } from "@logtape/redaction";

interface SecretRange {
  start: number;
  end: number;
}

function maskKnownSecrets(text: string, secrets: readonly string[]): string {
  const ranges: SecretRange[] = [];
  for (const secret of secrets.filter((value) => value.length > 0)) {
    let start = text.indexOf(secret);
    while (start !== -1) {
      ranges.push({ start, end: start + secret.length });
      start = text.indexOf(secret, start + 1);
    }
  }
  let result = "";
  let position = 0;
  let pending: SecretRange | undefined;
  for (const range of ranges.toSorted(
    (left, right) => left.start - right.start,
  )) {
    if (pending !== undefined && range.start < pending.end) {
      pending.end = Math.max(pending.end, range.end);
      continue;
    }
    if (pending !== undefined) {
      result += text.slice(position, pending.start) + "[redacted]";
      position = pending.end;
    }
    pending = { ...range };
  }
  if (pending !== undefined) {
    result += text.slice(position, pending.start) + "[redacted]";
    position = pending.end;
  }
  return result + text.slice(position);
}

export function diagnosticPatterns(
  secrets: readonly string[] = [],
): RedactionPattern[] {
  return [
    {
      pattern: /[\s\S]*\b(?:set-cookie|cookie)["']?\s*[:=]\s*\[[\s\S]*/giu,
      replacement: "[redacted cookie array]",
    },
    {
      pattern: /[\s\S]+/gu,
      replacement: (text: string) => maskKnownSecrets(text, secrets),
    },
    { ...JWT_PATTERN, replacement: "[redacted]" },
    {
      pattern:
        /\b((?:https?|mongodb(?:\+srv)?|rediss?|postgres(?:ql)?):\/\/)[^/\s?#@]+@/giu,
      replacement: "$1[redacted]@",
    },
    {
      pattern: /\b((?:Bearer|Basic)\s+)[A-Za-z0-9+/_=.-]+/giu,
      replacement: "$1[redacted]",
    },
    {
      pattern:
        /\b((?:authorization|set-cookie|cookie)["']?\s*[:=]\s*)[^\r\n]+/giu,
      replacement: "$1[redacted]",
    },
    {
      pattern:
        /\b([a-z0-9_-]*(?:password|secret|api[_-]?key|private[_-]?key|token)["']?\s*[:=]\s*)(?:"(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\(?:[\s\S]|$)|[^'\\])*(?:'|$)|[^\s,;]+)/giu,
      replacement: "$1[redacted]",
    },
    {
      pattern:
        /-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)/gu,
      replacement: "[redacted private key]",
    },
  ];
}
