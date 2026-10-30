import { errorText } from "./error-text.ts";
import { FrontendError, InvalidArgumentsError } from "./errors.ts";
import { parseArgs } from "node:util";
import { certificates } from "./certificates.ts";
import { loadConfig, upstreamPort } from "./config.ts";
import { checkHealth } from "./health.ts";
import { startProxy } from "./proxy.ts";

try {
  const { values, positionals } = parseArgs({
    options: {
      config: { type: "string" },
      help: { type: "boolean", short: "h" },
      version: { type: "boolean" },
    },
    allowPositionals: true,
  });
  if (values.help === true) {
    console.log(
      "Usage: claude-api-frontend <serve|check> --config FILE\n\nserve  Run the loopback frontend.\ncheck  Check the frontend certificate, configuration and TeamClaude connection.",
    );
  } else if (values.version === true) {
    console.log("0.1.0");
  } else {
    const command = positionals[0];
    if (
      positionals.length !== 1 ||
      (command !== "serve" && command !== "check") ||
      values.config === undefined
    ) {
      throw new InvalidArgumentsError();
    }
    const config = await loadConfig(values.config);
    if (command === "check") {
      await checkHealth(config);
    } else {
      const port = await upstreamPort(config);
      const chain = await certificates(config.stateDirectory);
      const proxy = await startProxy(config, port, chain);
      console.log(
        JSON.stringify({
          event: "listening",
          port: proxy.port,
          upstreamPort: port,
        }),
      );
      const renewal = setInterval(() => {
        certificates(config.stateDirectory)
          .then((replacement) => proxy.reloadCertificates(replacement))
          .catch((error: unknown) => {
            console.error(
              JSON.stringify({
                event: "certificate-renewal-failed",
                code:
                  error instanceof FrontendError
                    ? error.code
                    : "certificate-state",
              }),
            );
          });
      }, 7 * 86400000);

      renewal.unref();

      let stopping = false;
      const stop = (): void => {
        if (stopping) {
          return;
        }
        stopping = true;
        clearInterval(renewal);
        proxy.close().catch(() => {
          process.exitCode = 1;
        });
      };
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
    }
  }
} catch (error) {
  const text =
    error instanceof FrontendError
      ? errorText(error)
      : "Startup or health check failed. Check certificate paths, file permissions and OpenSSL installation.";

  console.error(`claude-api-frontend: ${text}`);
  process.exitCode = 1;
}
