import {
  CertificateExpiringError,
  CertificateStateError,
  ConfigurationReadError,
  FrontendError,
  HealthUnavailableError,
  InvalidConfigurationError,
  InvalidJsonError,
  ListenerError,
  PortConflictError,
  RequestTooLargeError,
} from "./errors.ts";

const descriptions: Readonly<Record<string, string>> = {
  "invalid-arguments":
    "Use claude-api-frontend <serve|check> --config FILE (or --help)",
  "loopback-disabled":
    "The frontend requires TeamClaude proxy.trustLoopback=true",
  "certificate-command": "OpenSSL certificate generation failed",
  "certificate-authority-changed":
    "The local CA changed. Restart the frontend and Claude sessions to trust the replacement",
  "unsupported-encoding": "Compressed inference requests are unsupported",
  "invalid-request-target": "Expected an Anthropic API request in origin form",
  "client-disconnected": "Client disconnected",
  "unexpected-listener": "Expected a TCP listener",
  upstream: "Could not forward request to TeamClaude",
};

export function errorText(error: FrontendError): string {
  if (error instanceof InvalidJsonError) {
    return `Invalid JSON in ${error.source} configuration or response`;
  }

  if (error instanceof InvalidConfigurationError) {
    return `Invalid ${error.source} configuration or response at: ${error.issues.map((issue) => issue.path.join(".")).join(", ")}`;
  }

  if (error instanceof ConfigurationReadError) {
    return `Could not read configuration at ${error.path}`;
  }

  if (error instanceof PortConflictError) {
    return `The frontend and TeamClaude both use port ${error.port}`;
  }

  if (error instanceof CertificateStateError) {
    return `Could not load certificate state from ${error.stateDirectory}`;
  }

  if (error instanceof CertificateExpiringError) {
    return `The frontend CA expires at ${error.validTo}. Remove its authority directory and restart the service and Claude sessions to renew it`;
  }

  if (error instanceof RequestTooLargeError) {
    return `Inference request exceeds the ${error.maxBodyBytes}-byte limit`;
  }

  if (error instanceof ListenerError) {
    return `Could not bind frontend loopback port ${error.port}`;
  }

  if (error instanceof HealthUnavailableError) {
    return `The ${error.service} health endpoint returned HTTP ${error.status}`;
  }

  return descriptions[error.code] ?? "Frontend operation failed";
}
