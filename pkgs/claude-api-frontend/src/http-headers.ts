import type { IncomingHttpHeaders } from "node:http";

export function headersWithoutHop(
  input: IncomingHttpHeaders,
): IncomingHttpHeaders {
  const headers = { ...input };
  const connection = headers.connection ?? "";
  const excluded = new Set([
    "host",
    "connection",
    "keep-alive",
    "transfer-encoding",
    "te",
    "trailer",
    "upgrade",
    "proxy-authorization",
    "proxy-authenticate",
    ...connection.split(",").map((value) => value.trim().toLowerCase()),
  ]);

  for (const key of Object.keys(headers)) {
    if (key.startsWith(":") || excluded.has(key)) {
      delete headers[key];
    }
  }

  return headers;
}
