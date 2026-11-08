import { StatusCodes } from "http-status-codes";

export type CredentialLabel =
  | "OpenAI"
  | "Anthropic"
  | "OpenRouter"
  | "Generated service";

interface CredentialReference {
  file: string;
  label: CredentialLabel;
}

export class CredentialReadError extends Error {
  readonly credential: CredentialReference;

  constructor(credential: CredentialReference, cause: unknown) {
    super(
      `Cannot read ${credential.label} credential file: ${credential.file}`,
      { cause },
    );

    this.name = "CredentialReadError";

    this.credential = credential;
  }
}

export class CredentialFormatError extends Error {
  readonly credential: CredentialReference;

  constructor(credential: CredentialReference) {
    super(
      `${credential.label} credential file must contain one non-empty line: ${credential.file}`,
    );

    this.name = "CredentialFormatError";

    this.credential = credential;
  }
}

export class OllamaEndpointError extends Error {
  constructor() {
    super(
      "Ollama requires an HTTP(S) endpoint without credentials, query or fragment",
    );

    this.name = "OllamaEndpointError";
  }
}

export class SessionOwnerError extends Error {
  constructor() {
    super(
      "Stored conversation identity does not match the configured principal",
    );

    this.name = "SessionOwnerError";
  }
}

export class WorkspaceQuarantinedError extends Error {
  constructor() {
    super(
      "Conversation workspace is quarantined and requires operator recovery",
    );

    this.name = "WorkspaceQuarantinedError";
  }
}

export class ConversationPrincipalError extends Error {
  constructor() {
    super("Conversation principal does not match the personal account");

    this.name = "ConversationPrincipalError";
  }
}

export class ConversationIdError extends Error {
  constructor() {
    super("Conversation ID must be a UUID");

    this.name = "ConversationIdError";
  }
}

export class RuntimeNotRegisteredError extends Error {
  constructor() {
    super("Runtime identity is not registered for an active conversation");

    this.name = "RuntimeNotRegisteredError";
  }
}

export class QuarantineTargetError extends Error {
  constructor() {
    super(
      "Cannot quarantine a runtime identity without a registered conversation",
    );

    this.name = "QuarantineTargetError";
  }
}

export class SessionStorageIdentityError extends Error {
  constructor() {
    super("Invalid runtime identity for session storage");

    this.name = "SessionStorageIdentityError";
  }
}

export class McpAuthenticationError extends Error {
  readonly status = StatusCodes.UNAUTHORIZED;

  constructor() {
    super("Unauthorised MCP request");

    this.name = "McpAuthenticationError";
  }
}

export class McpServerError extends Error {
  readonly status = StatusCodes.NOT_FOUND;

  constructor() {
    super("Unknown MCP server");

    this.name = "McpServerError";
  }
}

export class McpHttpMethodError extends Error {
  readonly status = StatusCodes.METHOD_NOT_ALLOWED;

  constructor() {
    super("Unsupported MCP HTTP method");

    this.name = "McpHttpMethodError";
  }
}

export class McpPrincipalError extends Error {
  readonly status = StatusCodes.FORBIDDEN;

  constructor() {
    super("Invalid MCP conversation principal");

    this.name = "McpPrincipalError";
  }
}

export class McpJsonError extends Error {
  readonly status = StatusCodes.BAD_REQUEST;

  constructor() {
    super("Invalid MCP JSON");

    this.name = "McpJsonError";
  }
}

export class McpRequestError extends Error {
  readonly status = StatusCodes.BAD_REQUEST;

  constructor() {
    super("Invalid MCP request");

    this.name = "McpRequestError";
  }
}

export class McpCatalogueExecutionError extends Error {
  readonly status = StatusCodes.FORBIDDEN;

  constructor() {
    super("Catalogue connections cannot execute tools or read workspace data");

    this.name = "McpCatalogueExecutionError";
  }
}

export class McpSessionError extends Error {
  readonly status = StatusCodes.NOT_FOUND;

  constructor() {
    super("MCP session is unknown or belongs to an earlier VM boot");

    this.name = "McpSessionError";
  }
}

export function mcpErrorResponse(
  error: Error & { readonly status: number },
): Response {
  return Response.json(
    { error: error.name, message: error.message },
    { status: error.status },
  );
}

export class SessionBusyError extends Error {
  constructor() {
    super("The workspace still has active calls; retry after they finish");

    this.name = "SessionBusyError";
  }
}

export class SessionClosingError extends Error {
  constructor() {
    super("The controller is draining active calls before shutdown");

    this.name = "SessionClosingError";
  }
}

export class WorkspaceRecoveryError extends Error {
  constructor(options?: ErrorOptions) {
    super(
      "Checkpoint recovery could not restart the workspace MCP processes",
      options,
    );

    this.name = "WorkspaceRecoveryError";
  }
}
