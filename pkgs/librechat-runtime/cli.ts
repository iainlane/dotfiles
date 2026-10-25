import { readFile } from "node:fs/promises";
import { Readable } from "node:stream";
import { z } from "zod";
import { archiveArguments } from "./archive.ts";
import {
  guestHttpService,
  guestSpecificationSchema,
  NodeGuestOperations,
} from "./guest.ts";
import { NodeProcessRunner } from "./processes.ts";
import { readCredential } from "./config.ts";

export class RuntimeCommandError extends Error {
  constructor() {
    super(
      "Use librechat-runtime guest <specification>, archive session <query>, or hook <configuration>",
    );

    this.name = "RuntimeCommandError";
  }
}

export class ArchiveQueryError extends Error {
  constructor() {
    super("The read-only AgentsView archive query failed");

    this.name = "ArchiveQueryError";
  }
}

export class ConversationHookError extends Error {
  constructor() {
    super(
      "The conversation controller could not prepare the workspace reminder",
    );

    this.name = "ConversationHookError";
  }
}

async function jsonFile(file: string): Promise<unknown> {
  return JSON.parse(await readFile(file, "utf8"));
}

function logError(error: unknown): void {
  if (error instanceof Error) {
    process.stderr.write(`${error.name}: ${error.message}\n`);

    return;
  }

  process.stderr.write("Unknown runtime failure\n");
}

async function main(args: string[]): Promise<void> {
  const [command, file] = args;

  if (command === "guest" && file !== undefined) {
    const specification = guestSpecificationSchema.parse(await jsonFile(file));

    const processes = new NodeProcessRunner({
      PATH: "/run/current-system/sw/bin",
      HOME: "/root",
    });

    const operations = new NodeGuestOperations(
      specification,
      processes,
      globalThis.fetch,
    );

    const server = guestHttpService(operations, logError);

    server.on("error", (error) => {
      logError(error);

      process.exitCode = 1;
    });

    server.listen(8080, "0.0.0.0");

    return;
  }

  if (command === "archive") {
    const query = archiveArguments(args.slice(1));

    const token =
      process.env.AGENTSVIEW_BROKER_TOKEN ??
      (await readCredential(
        "/run/librechat-guest/archive-token",
        "Generated service",
      ));

    const response = await fetch("http://10.0.2.102:3194/query", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(query),
      signal: AbortSignal.timeout(30_000),
    });

    if (!response.ok) {
      await response.body?.cancel();

      throw new ArchiveQueryError();
    }

    process.stdout.write(await response.text());

    return;
  }

  if (command === "hook" && file !== undefined) {
    const configuration = z
      .object({ tokenFile: z.string(), baseURL: z.url() })
      .parse(await jsonFile(file));

    const input: unknown = JSON.parse(
      await new Response(Readable.toWeb(process.stdin)).text(),
    );

    const payload = z.object({ session_id: z.uuid() }).parse(input);

    const token = await readCredential(
      configuration.tokenFile,
      "Generated service",
    );

    const response = await fetch(`${configuration.baseURL}/activate`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ conversationId: payload.session_id }),
      signal: AbortSignal.timeout(180_000),
    });

    if (!response.ok) {
      await response.body?.cancel();

      throw new ConversationHookError();
    }

    const result: unknown = await response.json();

    const reminder = z.object({ additionalContext: z.string() }).parse(result);

    process.stdout.write(`${JSON.stringify(reminder)}\n`);

    return;
  }

  throw new RuntimeCommandError();
}

try {
  await main(process.argv.slice(2));
} catch (error) {
  logError(error);

  process.exitCode = 1;
}
