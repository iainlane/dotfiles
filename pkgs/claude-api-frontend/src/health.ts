import { decodeJson, validate } from "./validation.ts";
import { X509Certificate } from "node:crypto";
import { NodeFrontendFiles, type FrontendFiles } from "./files.ts";
import { join } from "node:path";
import { z } from "zod";
import type { Config } from "./config.ts";
import { upstreamPort } from "./config.ts";
import { CertificateStateError, HealthUnavailableError } from "./errors.ts";
import { healthPath } from "./proxy.ts";
import { FetchTransport, type Transport } from "./transport.ts";

export interface HealthDependencies {
  transport: Transport;
  files: FrontendFiles;
}

const nativeDependencies: HealthDependencies = {
  transport: new FetchTransport(),
  files: new NodeFrontendFiles(),
};

export async function checkHealth(
  config: Config,
  dependencies: HealthDependencies = nativeDependencies,
): Promise<void> {
  const { transport, files } = dependencies;
  const port = await upstreamPort(config, files);
  let ca: X509Certificate;
  try {
    ca = new X509Certificate(
      await files.readBytes(join(config.stateDirectory, "authority", "ca.pem")),
    );
  } catch (cause) {
    throw new CertificateStateError(config.stateDirectory, { cause });
  }
  const reply = await transport.send(
    new Request(`http://127.0.0.1:${config.port}${healthPath}`, {
      signal: AbortSignal.timeout(2000),
    }),
  );
  const content = await reply.text();

  if (!reply.ok || content.length > 4096) {
    throw new HealthUnavailableError("frontend", reply.status);
  }

  const decoded = decodeJson(content, "health");

  validate(
    z.object({
      fingerprint: z.literal(ca.fingerprint256),
      upstreamPort: z.literal(port),
      account: z.literal(config.account),
    }),
    decoded,
    "health",
  );

  const upstream = await transport.send(
    new Request(`http://127.0.0.1:${port}/teamclaude/dashboard`, {
      signal: AbortSignal.timeout(2000),
    }),
  );
  await upstream.body?.cancel();

  if (!upstream.ok) {
    throw new HealthUnavailableError("teamclaude", upstream.status);
  }
}
