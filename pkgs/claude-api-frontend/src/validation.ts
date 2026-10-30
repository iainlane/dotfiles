import { z } from "zod";
import {
  InvalidConfigurationError,
  InvalidJsonError,
  type ValidationSource,
} from "./errors.ts";

export function decodeJson(text: string, source: ValidationSource): unknown {
  try {
    const decoded: unknown = JSON.parse(text);

    return decoded;
  } catch {
    throw new InvalidJsonError(source);
  }
}

export function validate<T>(
  schema: z.ZodType<T>,
  value: unknown,
  source: ValidationSource,
): T {
  const result = schema.safeParse(value);

  if (!result.success) {
    throw new InvalidConfigurationError(
      source,
      result.error.issues.map((issue) => ({
        code: issue.code,
        path: issue.path,
      })),
    );
  }

  return result.data;
}
