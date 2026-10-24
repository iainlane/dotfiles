import { parseRecord } from "./protocol.js";
import { createInterface } from "node:readline";

const tools: Record<string, string[]> = {
  context7: ["resolve-library-id", "query-docs"],
  "cloudflare-docs": ["search_cloudflare_documentation"],
  nixos: ["nix", "nix_versions"],
  exa: ["web_search_exa", "web_fetch_exa"],
};
const server = process.argv[2];
if (server === undefined || server === "" || !tools[server]) {
  throw new Error("Pass a known MCP fixture server");
}
for await (const line of createInterface({ input: process.stdin })) {
  const request = parseRecord(line);
  if (typeof request.id !== "string" && typeof request.id !== "number") {
    continue;
  }
  if (request.id === undefined) {
    continue;
  }
  const result =
    request.method === "initialize"
      ? {
          protocolVersion: "2025-03-26",
          capabilities: { tools: {} },
          serverInfo: { name: server, version: "1" },
        }
      : request.method === "tools/list"
        ? {
            tools: tools[server].map((name) => ({
              name,
              description: "Offline identifier fixture",
              inputSchema: { type: "object", properties: {} },
            })),
          }
        : {};
  process.stdout.write(
    JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) + "\n",
  );
}
