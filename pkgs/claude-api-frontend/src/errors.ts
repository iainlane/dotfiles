import { StatusCodes } from "http-status-codes";

export type ValidationSource = "frontend" | "teamclaude" | "health";

export interface ValidationIssue {
  code: string;
  path: PropertyKey[];
}

export abstract class FrontendError extends Error {
  abstract readonly code: string;

  toJSON(): Record<string, unknown> {
    return Object.fromEntries(Object.entries(this));
  }
}

export abstract class FrontendHttpError extends FrontendError {
  abstract readonly status: number;
}

export class InvalidArgumentsError extends FrontendError {
  readonly code = "invalid-arguments";
}

export class InvalidJsonError extends FrontendError {
  readonly code = "invalid-json";

  readonly source: ValidationSource;

  constructor(source: ValidationSource) {
    super();

    this.source = source;
  }
}

export class InvalidConfigurationError extends FrontendError {
  readonly code = "invalid-config";

  readonly source: ValidationSource;
  readonly issues: ValidationIssue[];

  constructor(source: ValidationSource, issues: ValidationIssue[]) {
    super();

    this.source = source;
    this.issues = issues;
  }
}

export class ConfigurationReadError extends FrontendError {
  readonly code = "config-read";

  readonly path: string;

  constructor(path: string, options: ErrorOptions) {
    super(undefined, options);

    this.path = path;
  }
}

export class LoopbackDisabledError extends FrontendError {
  readonly code = "loopback-disabled";
}

export class PortConflictError extends FrontendError {
  readonly code = "port-conflict";

  readonly port: number;

  constructor(port: number) {
    super();

    this.port = port;
  }
}

export class CertificateCommandError extends FrontendError {
  readonly code = "certificate-command";

  constructor(options: ErrorOptions) {
    super(undefined, options);
  }
}

export class CertificateExpiringError extends FrontendError {
  readonly code = "certificate-expiring";

  readonly validTo: string;

  constructor(validTo: string) {
    super();

    this.validTo = validTo;
  }
}

export class UpstreamError extends FrontendHttpError {
  readonly code = "upstream";
  readonly status = StatusCodes.BAD_GATEWAY;

  constructor(options: ErrorOptions) {
    super(undefined, options);
  }
}

export class RequestTooLargeError extends FrontendHttpError {
  readonly code = "request-too-large";
  readonly status = StatusCodes.REQUEST_TOO_LONG;

  readonly maxBodyBytes: number;

  constructor(maxBodyBytes: number) {
    super();

    this.maxBodyBytes = maxBodyBytes;
  }
}

export class UnsupportedEncodingError extends FrontendHttpError {
  readonly code = "unsupported-encoding";
  readonly status = StatusCodes.UNSUPPORTED_MEDIA_TYPE;

  readonly encoding: string;

  constructor(encoding: string) {
    super();

    this.encoding = encoding;
  }
}

export class InvalidRequestTargetError extends FrontendHttpError {
  readonly code = "invalid-request-target";
  readonly status = StatusCodes.BAD_REQUEST;
}

export class ClientDisconnectedError extends FrontendError {
  readonly code = "client-disconnected";
}

export class ListenerError extends FrontendError {
  readonly code = "listener";

  readonly port: number;

  constructor(port: number, options: ErrorOptions) {
    super(undefined, options);

    this.port = port;
  }
}

export class UnexpectedListenerError extends FrontendError {
  readonly code = "unexpected-listener";
}

export class HealthUnavailableError extends FrontendError {
  readonly code = "health-unavailable";

  readonly service: "frontend" | "teamclaude";
  readonly status: number;

  constructor(service: "frontend" | "teamclaude", status: number) {
    super();

    this.service = service;
    this.status = status;
  }
}

export class CertificateAuthorityChangedError extends FrontendError {
  readonly code = "certificate-authority-changed";
}

export class CertificateStateError extends FrontendError {
  readonly code = "certificate-state";
  readonly stateDirectory: string;

  constructor(stateDirectory: string, options: ErrorOptions) {
    super(undefined, options);

    this.stateDirectory = stateDirectory;
  }
}
