import { StatusCodes } from "http-status-codes";
import { z } from "zod";

const headerSchema = z.object({ values: z.array(z.string()) });

export const transformRequestSchema = z.object({
  request: z.object({
    method: z.string(),
    host: z.string(),
    url: z.string(),
    headers: z.record(z.string(), headerSchema),
  }),
  context: z.object({ sni: z.string().default("") }).default({ sni: "" }),
});

type TransformRequest = z.infer<typeof transformRequestSchema>;

interface TransformResult {
  action: 1 | 2;
  modifiedRequest?: { headers: TransformRequest["request"]["headers"] };
  response?: { statusCode: StatusCodes; body: Buffer };
}

const placeholder = "iron-github-placeholder";

const apiMethods = new Set([
  "GET",
  "HEAD",
  "POST",
  "PUT",
  "PATCH",
  "DELETE",
  "OPTIONS",
]);

const gitMethods = new Set(["GET", "HEAD", "POST"]);

function reject(statusCode: StatusCodes): TransformResult {
  return {
    action: 2,
    response: {
      statusCode,
      body: Buffer.from("GitHub credential request denied"),
    },
  };
}

function credentialFormat(
  value: string,
): "bearer" | "token" | "basic" | undefined {
  if (value === `Bearer ${placeholder}`) {
    return "bearer";
  }

  if (value === `token ${placeholder}`) {
    return "token";
  }

  if (
    value.startsWith("Basic ") &&
    Buffer.from(value.slice(6), "base64").toString("utf8") ===
      `x-access-token:${placeholder}`
  ) {
    return "basic";
  }

  return undefined;
}

function approvedOrigin(input: TransformRequest): boolean {
  const { request, context } = input;

  let url: URL;

  try {
    url = new URL(request.url, `https://${request.host}`);
  } catch {
    return false;
  }

  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    (url.port !== "" && url.port !== "443")
  ) {
    return false;
  }

  if (
    !["github.com", "api.github.com"].includes(url.hostname) ||
    context.sni !== url.hostname
  ) {
    return false;
  }

  if (![url.hostname, `${url.hostname}:443`].includes(request.host)) {
    return false;
  }

  if (url.hostname === "api.github.com") {
    return apiMethods.has(request.method) && url.pathname.startsWith("/");
  }

  return (
    gitMethods.has(request.method) &&
    /^\/[^/]+\/[^/]+\/(info\/refs|git-upload-pack|git-receive-pack)$/u.test(
      url.pathname,
    )
  );
}

export class GithubCredentialTransform {
  private readonly readToken: () => Promise<string>;

  constructor(readToken: () => Promise<string>) {
    this.readToken = readToken;
  }

  async request(input: TransformRequest): Promise<TransformResult> {
    const authorization = Object.entries(input.request.headers).filter(
      ([key]) => key.toLowerCase() === "authorization",
    );

    const formats = authorization.flatMap(([, header]) =>
      header.values.map(credentialFormat),
    );

    if (!formats.some((format) => format !== undefined)) {
      return { action: 1 };
    }

    if (
      authorization.length !== 1 ||
      formats.length !== 1 ||
      !approvedOrigin(input)
    ) {
      return reject(StatusCodes.FORBIDDEN);
    }

    const format = formats[0];

    let token: string;

    try {
      token = await this.readToken();
    } catch {
      return reject(StatusCodes.BAD_GATEWAY);
    }

    if (!/^\S+$/u.test(token)) {
      return reject(StatusCodes.BAD_GATEWAY);
    }

    const value =
      format === "basic"
        ? `Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`
        : `${format === "bearer" ? "Bearer" : "token"} ${token}`;
    const headers = { ...input.request.headers };

    const key = authorization[0]?.[0];

    if (key === undefined) {
      return reject(StatusCodes.FORBIDDEN);
    }
    headers[key] = { values: [value] };

    return { action: 1, modifiedRequest: { headers } };
  }
}
