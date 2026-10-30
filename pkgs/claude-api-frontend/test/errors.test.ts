import { StatusCodes } from "http-status-codes";
import { expect, it } from "vitest";
import {
  InvalidRequestTargetError,
  RequestTooLargeError,
  UnsupportedEncodingError,
  UpstreamError,
} from "../src/errors.ts";
import { errorResponse } from "../src/http-error.ts";
import { errorSnapshot } from "./fakes.ts";

const anyString: unknown = expect.any(String);

it.each([
  {
    error: new RequestTooLargeError(512),
    data: {
      code: "request-too-large",
      status: StatusCodes.REQUEST_TOO_LONG,
      maxBodyBytes: 512,
    },
    cause: undefined,
  },
  {
    error: new UnsupportedEncodingError("gzip"),
    data: {
      code: "unsupported-encoding",
      status: StatusCodes.UNSUPPORTED_MEDIA_TYPE,
      encoding: "gzip",
    },
    cause: undefined,
  },
  {
    error: new InvalidRequestTargetError(),
    data: { code: "invalid-request-target", status: StatusCodes.BAD_REQUEST },
    cause: undefined,
  },
  {
    error: new UpstreamError({ cause: { private: "credential" } }),
    data: { code: "upstream", status: StatusCodes.BAD_GATEWAY },
    cause: { private: "credential" },
  },
])(
  "maps structured error $data.code to its HTTP response",
  async ({ error, data, cause }) => {
    const response = errorResponse(error);
    const body: unknown = await response.json();

    expect({
      error: errorSnapshot(error),
      response: {
        status: response.status,
        headers: Object.fromEntries(response.headers),
        body,
      },
    }).toStrictEqual({
      error: { data, cause },
      response: {
        status: data.status,
        headers: {
          "cache-control": "no-store",
          "content-type": "application/json",
        },
        body: {
          error: { ...data, type: "frontend_error", message: anyString },
        },
      },
    });
  },
);
