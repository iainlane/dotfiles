import { appendFileSync } from "node:fs";
import { setupServer } from "msw/node";

const server = setupServer();

server.listen({
  onUnhandledRequest(request) {
    if (
      process.env.PI_FOOTER_NETWORK_LOG !== undefined &&
      process.env.PI_FOOTER_NETWORK_LOG !== ""
    ) {
      appendFileSync(
        process.env.PI_FOOTER_NETWORK_LOG,
        `${request.method} ${request.url}\n`,
      );
    }

    throw new Error("Network requests are disabled in footer TUI tests");
  },
});
