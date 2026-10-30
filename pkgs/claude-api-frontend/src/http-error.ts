import type http from "node:http";
import type http2 from "node:http2";
import { errorText } from "./error-text.ts";
import { FrontendHttpError, UpstreamError } from "./errors.ts";

interface HttpFailure {
  status: number;
  headers: Record<string, string>;
  body: { error: Record<string, unknown> };
}

export function httpFailure(cause: unknown): HttpFailure {
  const error =
    cause instanceof FrontendHttpError ? cause : new UpstreamError({ cause });

  return {
    status: error.status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
    },
    body: {
      error: {
        ...error.toJSON(),
        type: "frontend_error",
        message: errorText(error),
      },
    },
  };
}

export function errorResponse(cause: unknown): Response {
  const { body, ...init } = httpFailure(cause);

  return Response.json(body, init);
}

export function sendError(
  response: http.ServerResponse | http2.Http2ServerResponse,
  error: unknown,
): void {
  if (response.destroyed) {
    return;
  }

  if (response.headersSent) {
    response.destroy();

    return;
  }

  const reply = httpFailure(error);

  response.statusCode = reply.status;

  for (const [key, value] of Object.entries(reply.headers)) {
    response.setHeader(key, value);
  }

  response.end(JSON.stringify(reply.body));
}
