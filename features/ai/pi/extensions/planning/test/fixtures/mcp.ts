import { createInterface } from "node:readline";
import { Type } from "typebox";
import { Check } from "typebox/value";

const requestSchema = Type.Object({
  jsonrpc: Type.Literal("2.0"),
  method: Type.String(),
  id: Type.Optional(Type.Union([Type.String(), Type.Number()])),
});

for await (const line of createInterface({ input: process.stdin })) {
  let request: unknown;
  try {
    request = JSON.parse(line);
  } catch (error) {
    throw new Error("Expected a JSON-RPC request.", { cause: error });
  }
  if (!Check(requestSchema, request)) {
    throw new Error("Expected a JSON-RPC request.");
  }
  if (request.id === undefined) {
    continue;
  }
  const result =
    request.method === "initialize"
      ? {
          protocolVersion: "2025-03-26",
          capabilities: { tools: {} },
          serverInfo: { name: "fixture", version: "1" },
        }
      : request.method === "tools/list"
        ? {
            tools: ["inspect-tool", "mutate-tool"].map((name) => ({
              name,
              description: "Offline planning MCP fixture.",
              inputSchema: { type: "object", properties: {} },
              annotations: { readOnlyHint: true },
            })),
          }
        : { content: [{ type: "text", text: "fixture:mcp" }] };
  process.stdout.write(
    JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) + "\n",
  );
}
