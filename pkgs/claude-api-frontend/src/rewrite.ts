import { z } from "zod";

const payloadSchema = z.looseObject({ system: z.unknown().optional() });
const textBlockSchema = z.looseObject({
  type: z.literal("text"),
  text: z.string(),
});
const billingLine = /^[\t ]*x-anthropic-billing-header:[^\r\n]*(?:\r?\n|$)/gm;

export function rewriteHeaders(input: Headers): Headers {
  const headers = new Headers(input);
  const userAgent = headers.get("user-agent");

  if (userAgent !== null) {
    headers.set(
      "user-agent",
      userAgent.replace("(external, cli)", "(external, sdk-cli)"),
    );
  }

  const beta = headers.get("anthropic-beta");

  if (beta !== null) {
    const values = beta
      .split(",")
      .map((value) => value.trim())
      .filter((value) => value.length > 0 && value !== "claude-code-20250219");

    headers.delete("anthropic-beta");

    if (values.length > 0) {
      headers.set("anthropic-beta", values.join(","));
    }
  }

  return headers;
}

export function rewriteBody(body: Uint8Array): Uint8Array {
  let decoded: unknown;

  try {
    decoded = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return body;
  }

  const parsed = payloadSchema.safeParse(decoded);

  if (!parsed.success) {
    return body;
  }

  const payload = parsed.data;
  let changed = false;
  const strip = (text: string): string =>
    text.replaceAll(billingLine, () => {
      changed = true;
      return "";
    });

  if (typeof payload.system === "string") {
    payload.system = strip(payload.system);
  }

  if (Array.isArray(payload.system)) {
    payload.system = payload.system.flatMap((block: unknown) => {
      const parsedBlock = textBlockSchema.safeParse(block);

      if (!parsedBlock.success) {
        return [block];
      }
      const text = strip(parsedBlock.data.text);

      if (text === parsedBlock.data.text) {
        return [block];
      }

      if (text.trim().length === 0) {
        return [];
      }

      return [{ ...parsedBlock.data, text }];
    });
  }

  if (changed && Array.isArray(payload.system) && payload.system.length === 0) {
    delete payload.system;
  }

  return changed ? new TextEncoder().encode(JSON.stringify(payload)) : body;
}
