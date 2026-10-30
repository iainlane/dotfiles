import { decodeJson, validate } from "./validation.ts";
import { X509Certificate } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import type { Config } from "./config.ts";
import { upstreamPort } from "./config.ts";
import { HealthUnavailableError } from "./errors.ts";
import { healthPath } from "./proxy.ts";
import { FetchTransport, type Transport } from "./transport.ts";

export async function checkHealth(
  config: Config,
  transport: Transport = new FetchTransport(),
): Promise<void> {
  const port = await upstreamPort(config);
  const ca = new X509Certificate(
    await readFile(join(config.stateDirectory, "authority", "ca.pem")),
  );
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
