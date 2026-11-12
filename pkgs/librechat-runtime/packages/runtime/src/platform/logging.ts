import { inspect } from "node:util";
import {
  getAnsiColorFormatter,
  getJsonLinesFormatter,
  type Sink,
} from "@logtape/logtape";
import { redactByField, redactByPattern } from "@logtape/redaction";
import { z } from "zod";
import { diagnosticPatterns } from "#runtime/platform/redaction";

interface DiagnosticOutput {
  write(text: string): void;
  terminal?: boolean;
  secrets?: readonly string[];
}

export function diagnosticSink(output: DiagnosticOutput): Sink {
  const redact = redactByPattern(
    (record) => [record.message, record.properties],
    diagnosticPatterns(output.secrets),
  );
  const formatter =
    output.terminal === true
      ? getAnsiColorFormatter({
          format: ({ timestamp, level, category, message, record }) =>
            `${timestamp} [${level}] ${category}: ${message}\n${inspect(record.properties, { colors: true, depth: 8 })}`,
        })
      : getJsonLinesFormatter({ properties: "flatten" });
  return redactByField(
    (record) => {
      const [message, properties] = redact(record);
      output.write(
        formatter({
          ...record,
          message: z.array(z.unknown()).parse(message),
          properties: z.record(z.string(), z.unknown()).parse(properties),
        }),
      );
    },
    {
      fieldPatterns: [
        /password|passphrase|secret|token|api[_-]?key|private[_-]?key|authorization|cookie/iu,
      ],
      action: () => "[redacted]",
    },
  );
}
