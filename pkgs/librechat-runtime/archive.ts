import { StatusCodes } from "http-status-codes";
import { parseArgs } from "node:util";
import { z } from "zod";
import { authorised } from "./mcp-router.ts";

export class ArchiveArgumentsError extends Error {
  constructor() {
    super(
      "The archive broker accepts only bounded session search and message queries",
    );

    this.name = "ArchiveArgumentsError";
  }
}

const argumentSchema = z.array(z.string().max(4096)).max(40);

const shared = {
  limit: { type: "string" },
  json: { type: "boolean" },
} as const;

const search = {
  ...shared,
  hybrid: { type: "boolean" },
  context: { type: "string" },
  project: { type: "string" },
  agent: { type: "string" },
  in: { type: "string" },
  "exclude-session": { type: "string" },
} as const;

const messages = {
  ...shared,
  from: { type: "string" },
  direction: { type: "string" },
  around: { type: "string" },
  before: { type: "string" },
  after: { type: "string" },
  role: { type: "string" },
} as const;

export function archiveArguments(input: unknown): string[] {
  const supplied = argumentSchema.safeParse(input);

  if (
    !supplied.success ||
    supplied.data[0] !== "session" ||
    !["search", "messages"].includes(supplied.data[1] ?? "")
  ) {
    throw new ArchiveArgumentsError();
  }

  const operation = supplied.data[1];

  let parsed: { values: Record<string, unknown>; positionals: string[] };

  try {
    parsed = parseArgs({
      args: supplied.data.slice(2),
      options: operation === "search" ? search : messages,
      allowPositionals: true,
      strict: true,
    });
  } catch {
    throw new ArchiveArgumentsError();
  }

  if (parsed.positionals.length !== 1) {
    throw new ArchiveArgumentsError();
  }

  for (const name of [
    "limit",
    "context",
    "from",
    "around",
    "before",
    "after",
  ]) {
    const value = parsed.values[name];

    if (
      value !== undefined &&
      (typeof value !== "string" ||
        !/^\d{1,5}$/u.test(value) ||
        Number(value) > 500)
    ) {
      throw new ArchiveArgumentsError();
    }
  }

  if (Number(parsed.values.limit) === 0) {
    throw new ArchiveArgumentsError();
  }

  const args = ["session", operation ?? "", "--json"];

  for (const [key, value] of Object.entries(parsed.values)) {
    if (key === "json") {
      continue;
    }

    if (value === true) {
      args.push(`--${key}`);
      continue;
    }

    if (typeof value === "string") {
      args.push(`--${key}`, value);
    }
  }

  if (parsed.values.limit === undefined) {
    args.push("--limit", "50");
  }

  args.push("--", ...parsed.positionals);

  return args;
}

export class ArchiveBroker {
  private readonly token: string;
  private readonly query: (args: string[]) => Promise<string>;

  constructor(token: string, query: (args: string[]) => Promise<string>) {
    this.token = token;

    this.query = query;
  }

  async route(request: Request): Promise<Response> {
    if (!authorised(request.headers.get("authorization"), this.token)) {
      return new Response(null, { status: StatusCodes.UNAUTHORIZED });
    }

    if (
      request.method !== "POST" ||
      new URL(request.url).pathname !== "/query"
    ) {
      return new Response(null, { status: StatusCodes.NOT_FOUND });
    }

    let args: string[];

    try {
      const raw: unknown = await request.json();

      args = archiveArguments(raw);
    } catch (error) {
      return Response.json(
        { error: error instanceof Error ? error.name : "ArchiveRequestError" },
        { status: StatusCodes.BAD_REQUEST },
      );
    }

    const result = await this.query(args);

    return new Response(result, {
      headers: { "content-type": "application/json" },
    });
  }
}
