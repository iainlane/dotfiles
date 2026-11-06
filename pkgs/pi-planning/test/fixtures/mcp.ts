import { existsSync, watch } from "node:fs";
import { dirname } from "node:path";
import { createInterface } from "node:readline";
import { Type } from "typebox";
import { Check } from "typebox/value";

const requestSchema = Type.Object({
  jsonrpc: Type.Literal("2.0"),
  method: Type.String(),
  id: Type.Optional(Type.Union([Type.String(), Type.Number()])),
});

async function waitForGate(path: string): Promise<void> {
  await new Promise<void>((resolve) => {
    const ready = () => {
      if (!existsSync(path)) {
        return;
      }
      watcher.close();
      resolve();
    };
    const watcher = watch(dirname(path), ready);
    ready();
  });
}

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
  const gate = process.argv[2];
  if (request.method === "tools/list" && gate !== undefined) {
    await waitForGate(gate);
  }
  const result =
    request.method === "initialize"
      ? {
          protocolVersion: "2025-03-26",
          capabilities: { tools: {}, resources: {} },
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
        : request.method === "resources/list"
          ? {
              resources: [{ uri: "fixture://document", name: "document" }],
            }
          : request.method === "resources/templates/list"
            ? {
                resourceTemplates: [
                  { uriTemplate: "fixture://{name}", name: "document" },
                ],
              }
            : request.method === "resources/read"
              ? {
                  contents: [
                    {
                      uri: "fixture://document",
                      text: "Offline resource contents.",
                    },
                  ],
                }
              : { content: [{ type: "text", text: "fixture:mcp" }] };
  process.stdout.write(
    JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) + "\n",
  );
}
