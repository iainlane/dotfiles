import { StatusCodes } from "http-status-codes";
import { request as httpRequest, type RequestOptions } from "node:http";
import { Readable } from "node:stream";

export type SocketFetch = (
  socket: string,
  request: Request,
) => Promise<Response>;

export class GuestTransportError extends Error {
  constructor(cause: unknown) {
    super("The conversation VM control connection failed", { cause });

    this.name = "GuestTransportError";
  }
}

export async function sendHttpRequest(
  connection: Pick<RequestOptions, "socketPath" | "createConnection">,
  request: Request,
  failure: (cause: unknown) => Error,
): Promise<Response> {
  return await new Promise<Response>((resolve, reject) => {
    const url = new URL(request.url);

    const outgoing = httpRequest(
      {
        ...connection,
        path: `${url.pathname}${url.search}`,
        method: request.method,
        headers: Object.fromEntries(request.headers),
        signal: request.signal,
      },
      (incoming) => {
        const headers = new Headers();

        for (const [name, value] of Object.entries(incoming.headers)) {
          if (value !== undefined) {
            headers.set(name, Array.isArray(value) ? value.join(", ") : value);
          }
        }

        const status = incoming.statusCode ?? StatusCodes.BAD_GATEWAY;

        if (
          [
            StatusCodes.NO_CONTENT,
            StatusCodes.RESET_CONTENT,
            StatusCodes.NOT_MODIFIED,
          ].includes(status)
        ) {
          incoming.resume();

          resolve(new Response(null, { status, headers }));

          return;
        }

        resolve(new Response(Readable.toWeb(incoming), { status, headers }));
      },
    );

    outgoing.on("error", (cause: unknown) => {
      reject(failure(cause));
    });

    if (request.body === null) {
      outgoing.end();

      return;
    }

    const body = Readable.fromWeb(request.body);

    body.on("error", (cause: unknown) => {
      outgoing.destroy(failure(cause));
    });

    body.pipe(outgoing);
  });
}

export const fetchSocket: SocketFetch = async (socket, request) =>
  await sendHttpRequest(
    { socketPath: socket },
    request,
    (cause) => new GuestTransportError(cause),
  );
