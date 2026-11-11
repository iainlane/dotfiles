import {
  argument,
  command,
  description,
  extend,
  name,
  option,
  parse,
  printHelp,
  printVersion,
  route,
  schema,
  toggle,
  version,
} from "@bomb.sh/router";
import { z } from "zod";
import {
  archiveArguments,
  ArchiveArgumentsError,
} from "@dotfiles/librechat-runtime/archive";
import {
  ArchiveArgumentsUsageError,
  CommandArgumentsError,
} from "#cli/application/errors";

export type EntryPoint = "public" | "runtime";

export const emailSchema = z.email().transform((email) => email.toLowerCase());
export const displayNameSchema = z.string().trim().min(3).max(80);
export const conversationSchema = z.uuid();
const fileSchema = z.string().min(1);
const countSchema = z.number().int().min(0).max(500);

const yes = toggle(
  name("yes"),
  description("Accept confirmations; missing inputs are still required."),
);
const bootstrapOptions = extend(
  yes,
  option(
    name("email"),
    description("Email address for your personal account."),
    schema(emailSchema.optional()),
  ),
  option(
    name("name"),
    description("Your display name (3 to 80 characters)."),
    schema(displayNameSchema.optional()),
  ),
  option(
    name("passwordFile"),
    description(
      "UTF-8 password file; required only for a new account without interactive input.",
    ),
    schema(fileSchema.optional()),
  ),
);
const resetOptions = extend(
  yes,
  option(
    name("conversation"),
    description("UUID of the conversation workspace to delete."),
    schema(conversationSchema.optional()),
  ),
);
const bootstrapDescription = description(
  "Create your administrator account or update its display name and personal agents.",
);
const resetDescription = description(
  "Delete a conversation workspace, including unpushed work.",
);

const publicDefinition = command(
  name("librechatctl"),
  description(
    "Manage your local LibreChat account and conversation workspaces.",
  ),
  version("0.1.0"),
  yes,
  command(name("bootstrap"), bootstrapDescription, bootstrapOptions),
  command(name("reset"), resetDescription, resetOptions),
);

const archiveOptions = extend(
  yes,
  toggle(
    name("json"),
    description("Return the archive broker's JSON response."),
  ),
  option(name("limit"), schema(countSchema.min(1).optional())),
);
const runtimeDefinition = command(
  name("librechat-runtime"),
  description("Run LibreChat services and guest protocols."),
  version("0.1.0"),
  yes,
  command(
    name("bootstrap"),
    bootstrapDescription,
    bootstrapOptions,
    argument(name("manifest"), schema(fileSchema)),
  ),
  command(
    name("reset"),
    resetDescription,
    resetOptions,
    argument(name("manifest"), schema(fileSchema)),
  ),
  command(
    name("serve"),
    description("Start the host services."),
    yes,
    argument(name("file"), schema(fileSchema)),
  ),
  command(
    name("guest"),
    description("Start the guest service."),
    yes,
    argument(name("file"), schema(fileSchema)),
  ),
  command(
    name("hook"),
    description("Process a conversation activity hook."),
    yes,
    argument(name("file"), schema(fileSchema)),
  ),
  route(
    name("archive"),
    description("Query the read-only conversation archive."),
    yes,
    route(
      name("session"),
      yes,
      command(
        name("search"),
        description("Search archived sessions."),
        archiveOptions,
        argument(name("value"), schema(z.string().max(4096).optional())),
        toggle(name("hybrid")),
        option(name("context"), schema(countSchema.optional())),
        option(name("project"), schema(z.string().optional())),
        option(name("agent"), schema(z.string().optional())),
        option(name("in"), schema(z.string().optional())),
        option(name("excludeSession"), schema(z.string().optional())),
      ),
      command(
        name("messages"),
        description("Read archived session messages."),
        archiveOptions,
        argument(name("value"), schema(z.string().max(4096).optional())),
        option(name("from"), schema(countSchema.optional())),
        option(name("direction"), schema(z.string().optional())),
        option(name("around"), schema(countSchema.optional())),
        option(name("before"), schema(countSchema.optional())),
        option(name("after"), schema(countSchema.optional())),
        option(name("role"), schema(z.string().optional())),
      ),
    ),
  ),
);

export interface BootstrapOptions {
  email: string | undefined;
  name: string | undefined;
  passwordFile: string | undefined;
  yes: boolean;
}

export type CommandIntent =
  | { kind: "help" | "version"; text: string }
  | ({ kind: "bootstrap"; manifest: string | undefined } & BootstrapOptions)
  | {
      kind: "reset";
      manifest: string | undefined;
      conversation: string | undefined;
      yes: boolean;
    }
  | { kind: "serve" | "guest" | "hook"; file: string }
  | { kind: "archive"; query: string[] };

function archiveQuery(
  operation: "search" | "messages",
  values: Readonly<Record<string, string | number | boolean | undefined>>,
  literals: Iterable<{ text: string }>,
): string[] {
  const escaped = Array.from(literals, (literal) => literal.text);
  const value = values.value;
  const positionals = value === undefined ? escaped : [value, ...escaped];
  const args = ["session", operation];

  for (const [key, supplied] of Object.entries(values)) {
    if (
      ["value", "yes", "json"].includes(key) ||
      supplied === undefined ||
      supplied === false
    ) {
      continue;
    }

    args.push(`--${key === "excludeSession" ? "exclude-session" : key}`);
    if (supplied !== true) {
      args.push(String(supplied));
    }
  }

  args.push("--", ...positionals.map(String));
  try {
    return archiveArguments(args);
  } catch (cause) {
    if (cause instanceof ArchiveArgumentsError) {
      throw new ArchiveArgumentsUsageError(cause);
    }
    throw cause;
  }
}

function examples(entry: EntryPoint, routeName: string): string[] {
  const program = entry === "public" ? "librechatctl" : "librechat-runtime";
  const manifest = entry === "public" ? "" : " ./manifest.json";
  const commands: Readonly<Record<string, string[]>> = {
    "/": [
      `${program} bootstrap${manifest}`,
      `${program} reset${manifest} --conversation CONVERSATION_UUID --yes`,
    ],
    "/bootstrap": [
      `${program} bootstrap${manifest}`,
      `${program} bootstrap${manifest} --email you@example.com --name 'Your Name' --password-file ./password`,
    ],
    "/reset": [
      `${program} reset${manifest}`,
      `${program} --yes reset${manifest} --conversation CONVERSATION_UUID`,
    ],
    "/serve": [`${program} serve ./manifest.json`],
    "/guest": [`${program} guest ./specification.json`],
    "/hook": [`${program} hook ./configuration.json < hook.json`],
    "/archive/session/search": [
      `${program} archive session search 'search text' --limit 50`,
    ],
    "/archive/session/messages": [
      `${program} archive session messages SESSION_ID --limit 50`,
    ],
  };
  return commands[routeName] ?? [];
}

export function parseCommand(args: string[], entry: EntryPoint): CommandIntent {
  const argv = args.length === 0 ? ["--help"] : args;
  const result =
    entry === "public"
      ? parse(publicDefinition, { argv })
      : parse(runtimeDefinition, { argv });
  const program = entry === "public" ? "librechatctl" : "librechat-runtime";

  if (!result.ok) {
    throw new CommandArgumentsError(
      entry,
      result.path,
      result.code === "unprocessable-content"
        ? result.issues.map((issue) => {
            const field = issue.path?.[0];
            return { path: typeof field === "string" ? [field] : [] };
          })
        : [],
    );
  }

  if (result.method === "help") {
    return {
      kind: "help",
      text: [
        printHelp({
          ...result,
          path: result.path.length === 0 ? [] : [program, ...result.path],
        }),
        "Examples",
        ...examples(entry, result.route).map((example) => `  ${example}`),
      ].join("\n"),
    };
  }

  if (result.method === "version") {
    return { kind: "version", text: printVersion(result) };
  }

  switch (result.route) {
    case "/":
      return parseCommand(["--help"], entry);
    case "/bootstrap":
      return {
        kind: "bootstrap",
        manifest:
          "manifest" in result.model &&
          typeof result.model.manifest === "string"
            ? result.model.manifest
            : undefined,
        email: result.model.email,
        name: result.model.name,
        passwordFile: result.model.passwordFile,
        yes: result.model.yes || result.models["/"].yes,
      };
    case "/reset":
      return {
        kind: "reset",
        manifest:
          "manifest" in result.model &&
          typeof result.model.manifest === "string"
            ? result.model.manifest
            : undefined,
        conversation: result.model.conversation,
        yes: result.model.yes || result.models["/"].yes,
      };
    case "/serve":
      return { kind: "serve", file: result.model.file };
    case "/guest":
      return { kind: "guest", file: result.model.file };
    case "/hook":
      return { kind: "hook", file: result.model.file };
    case "/archive/session/search":
      return {
        kind: "archive",
        query: archiveQuery("search", result.model, result.literals),
      };
    case "/archive/session/messages":
      return {
        kind: "archive",
        query: archiveQuery("messages", result.model, result.literals),
      };
  }

  throw new CommandArgumentsError(entry, []);
}
