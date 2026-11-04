import { Type } from "typebox";
import { Check } from "typebox/value";
import { exportedFunction, isRecord, parseRecord } from "./protocol.js";
import { ChildProcess } from "node:child_process";
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { Socket } from "node:net";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const registrySchema = Type.Object({
  registeredServers: Type.Array(
    Type.Object({
      id: Type.String(),
      spawn: Type.Function(
        [Type.String(), Type.Object({ allowInstall: Type.Literal(false) })],
        Type.Unknown(),
      ),
    }),
  ),
});
const configSchema = Type.Object({
  lsp: Type.Record(Type.String(), Type.Unknown()),
});
const messageSchema = Type.Object({
  jsonrpc: Type.Literal("2.0"),
  id: Type.Optional(Type.Union([Type.Number(), Type.String(), Type.Null()])),
  method: Type.Optional(Type.String()),
  result: Type.Optional(Type.Unknown()),
  params: Type.Optional(Type.Unknown()),
});
const diagnosticsSchema = Type.Object({
  diagnostics: Type.Array(Type.Unknown()),
});
const selectedDiagnosticSchema = Type.Object({ code: Type.Literal(2322) });
const [packageRoot, configFile] = process.argv.slice(2);
assert.ok(
  packageRoot !== undefined &&
    packageRoot !== "" &&
    configFile !== undefined &&
    configFile !== "",
  "Pass the installed Lens directory and generated configuration",
);
const config = parseRecord(await readFile(configFile, "utf8"));
assert.ok(Check(configSchema, config), "Expected a Lens LSP configuration");
let registry: import("typebox").Static<typeof registrySchema> | undefined;
const candidates = await Promise.all(
  (await readdir(join(packageRoot, "dist")))
    .filter((entry) => entry.startsWith("chunk-") && entry.endsWith(".js"))
    .map(async (entry) => {
      const path = join(packageRoot, "dist", entry);
      const source = await readFile(path, "utf8");
      const exposesRegistry = (source.match(/export \{([^}]+)\};/)?.[1] ?? "")
        .split(",")
        .some((value) => value.trim() === "registerLSPConfig");
      return exposesRegistry ? path : undefined;
    }),
);
const path = candidates.find((candidate) => candidate !== undefined);
if (path !== undefined) {
  const module: unknown = await import(pathToFileURL(path).href);
  const value = exportedFunction(module, "registerLSPConfig")(config.lsp);
  assert.ok(Check(registrySchema, value), "Expected the Lens LSP registry");
  registry = value;
}
assert.ok(registry, "Lens must expose its LSP registry");
const server = registry.registeredServers.find(
  (entry) => entry.id === "typescript",
);
assert.ok(server, "The TypeScript language server must remain registered");
const root = await mkdtemp(join(tmpdir(), "pi-lsp-"));
const launchDeadline = Promise.withResolvers<never>();
const launching = setTimeout(
  () =>
    launchDeadline.reject(
      new Error(
        "Lens did not launch the TypeScript language server within 20 seconds",
      ),
    ),
  20_000,
);
let launched: unknown;
try {
  launched = await Promise.race([
    server.spawn(root, { allowInstall: false }),
    launchDeadline.promise,
  ]);
} finally {
  clearTimeout(launching);
}
assert.ok(
  launched !== undefined && launched !== null,
  "The selected TypeScript server must start without installing tools",
);
assert.ok(
  isRecord(launched) &&
    isRecord(launched.process) &&
    launched.process.process instanceof ChildProcess,
);
const child = launched.process.process;
const { stdin, stdout, stderr } = child;
assert.ok(
  stdin && stdout && stderr,
  "The LSP process must use piped standard streams",
);
child.ref();
for (const stream of [stdin, stdout, stderr]) {
  if (stream instanceof Socket) {
    stream.ref();
  }
}
const exited = once(child, "exit");
const diagnostic = Promise.withResolvers<unknown>();
const pending = new Map<number, (result: unknown) => void>();
let sequence = 0;
let buffer = Buffer.alloc(0);
let errors = "";
stderr.on("data", (chunk: Buffer) => {
  errors += chunk.toString();
});
const send = (value: unknown) => {
  const message = JSON.stringify(value);
  stdin.write(
    `Content-Length: ${Buffer.byteLength(message)}\r\n\r\n${message}`,
  );
};
const request = (method: string, params?: unknown) =>
  new Promise<unknown>((resolve) => {
    const id = ++sequence;
    pending.set(id, resolve);
    send({ jsonrpc: "2.0", id, method, params });
  });
stdout.on("data", (chunk: Buffer) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const end = buffer.indexOf("\r\n\r\n");
    if (end < 0) {
      return;
    }
    const size = Number(
      buffer
        .subarray(0, end)
        .toString()
        .match(/Content-Length: (\d+)/i)?.[1],
    );
    if (!Number.isFinite(size) || buffer.length < end + 4 + size) {
      return;
    }
    const message = parseRecord(
      buffer.subarray(end + 4, end + 4 + size).toString(),
    );
    assert.ok(
      Check(messageSchema, message),
      "Expected an LSP JSON-RPC message",
    );
    buffer = buffer.subarray(end + 4 + size);
    if (
      message.method !== undefined &&
      message.id !== undefined &&
      message.id !== null
    ) {
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: message.method === "workspace/configuration" ? [] : null,
      });
    } else if (typeof message.id === "number") {
      pending.get(message.id)?.(message.result);
      pending.delete(message.id);
    } else if (message.method === "textDocument/publishDiagnostics") {
      const selected = Check(diagnosticsSchema, message.params)
        ? message.params.diagnostics.filter((entry: unknown) =>
            Check(selectedDiagnosticSchema, entry),
          )
        : [];
      if (selected.length > 0) {
        diagnostic.resolve(selected);
      }
    }
  }
});
const deadline = Promise.withResolvers<never>();
const timer = setTimeout(
  () =>
    deadline.reject(new Error(`TypeScript diagnostics timed out: ${errors}`)),
  20_000,
);
try {
  await Promise.race([
    (async () => {
      await request("initialize", {
        processId: process.pid,
        rootUri: pathToFileURL(root).href,
        capabilities: { textDocument: { publishDiagnostics: {} } },
        initializationOptions: {},
      });
      send({ jsonrpc: "2.0", method: "initialized", params: {} });
      send({
        jsonrpc: "2.0",
        method: "textDocument/didOpen",
        params: {
          textDocument: {
            uri: pathToFileURL(join(root, "fallback.ts")).href,
            languageId: "typescript",
            version: 1,
            text: 'const answer: number = "incorrect";\n',
          },
        },
      });
      assert.deepStrictEqual(await diagnostic.promise, [
        {
          range: {
            start: { line: 0, character: 6 },
            end: { line: 0, character: 12 },
          },
          message: "Type 'string' is not assignable to type 'number'.",
          severity: 1,
          code: 2322,
          source: "typescript",
        },
      ]);
      await request("shutdown");
      send({ jsonrpc: "2.0", method: "exit" });
      await exited;
    })(),
    deadline.promise,
  ]);
} finally {
  clearTimeout(timer);
  child.kill();
  await rm(root, { recursive: true, force: true });
}
