import { strict as assert } from "node:assert";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { z } from "zod";
import { hostManifestSchema } from "../../src/manifest.ts";
import { NodeProcessRunner, type ManagedProcess } from "../../src/processes.ts";
import { QemuBackend } from "../../src/vm-backend.ts";
import { FileVmStorage } from "../../src/vm-files.ts";
import { fetchSocket } from "../../src/http-socket.ts";
import { stopExistingVm } from "../../src/vm-monitor.ts";
import { startFileServer } from "../../src/file-server.ts";
import { httpReady } from "../../src/startup.ts";
import type { Session } from "../../src/sessions.ts";

const configuration = z
  .object({
    manifest: z.object({
      programs: hostManifestSchema.shape.programs.pick({
        qemu: true,
        socat: true,
        redis: true,
        rustfs: true,
        fileServer: true,
        egressGateway: true,
        iron: true,
      }),
      guest: hostManifestSchema.shape.guest,
    }),
    codeSource: z.string(),
    bashVersion: z.string(),
    bash: z.string(),
    coreutils: z.string(),
    system: z.string(),
  })
  .parse(JSON.parse(await readFile(process.argv[2] ?? "", "utf8")));

const signing = z
  .object({
    signExecutionManifestWithPrivateKey: z.function({
      input: [z.record(z.string(), z.unknown()), z.string()],
      output: z.string(),
    }),
    executionManifestBodySha256: z.function({
      input: [z.unknown()],
      output: z.string(),
    }),
  })
  .parse(
    await import(
      pathToFileURL(
        join(configuration.codeSource, "service/src/execution-manifest.ts"),
      ).href
    ),
  );

async function freePort(): Promise<number> {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = z.object({ port: z.number() }).parse(server.address());
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
  return port;
}

const root = await mkdtemp("/tmp/lcw-");
const environment = z
  .record(z.string(), z.string())
  .parse(
    Object.fromEntries(
      Object.entries(process.env).filter(([, value]) => value !== undefined),
    ),
  );
const processes = new NodeProcessRunner({ ...environment, HOME: root });
const children: ManagedProcess[] = [];
const programs = configuration.manifest.programs;
const [redisPort, objectPort, consolePort, gatewayPort, ironPort, archivePort] =
  z
    .tuple([
      z.number(),
      z.number(),
      z.number(),
      z.number(),
      z.number(),
      z.number(),
    ])
    .parse(await Promise.all(Array.from({ length: 6 }, freePort)));
let filePort = 0;
const internal = "workspace-fixture-internal-token-32-bytes";
const secret = "workspace-fixture-object-secret-32-bytes";
const session: Session = {
  runtimeId: `rt_${"a".repeat(40)}`,
  userId: "fixture",
  conversationId: null,
  generation: 1,
  lastUsed: 0,
  checkpoint: false,
  expired: false,
  resetReason: "",
  quarantine: null,
};
const keys = generateKeyPairSync("ed25519");
const privateKey = keys.privateKey
  .export({ format: "der", type: "pkcs8" })
  .toString("base64");
const publicKey = keys.publicKey
  .export({ format: "der", type: "spki" })
  .toString("base64");
const runtime = {
  executable: programs.qemu,
  forwarder: programs.socat,
  architecture: configuration.manifest.guest.architecture,
  accelerator: configuration.manifest.guest.accelerator,
  memoryMiB: 2048,
  cpus: 2,
};
const files = new FileVmStorage({
  directory: join(root, "sessions"),
  socketDirectory: join(root, "sockets"),
  uid: process.getuid?.() ?? 0,
  ...configuration.manifest.guest,
  checkpointMaxBytes: 8 * 1024 ** 3,
  runtime,
  retainRuntime: async () => {},
  createDisk: async (image, destination) => {
    await processes.run({
      executable: join(dirname(programs.qemu), "qemu-img"),
      args: ["create", "-f", "qcow2", "-F", "qcow2", "-b", image, destination],
    });
  },
  stopExistingVm,
});
let failure: unknown;
let guest: Awaited<ReturnType<QemuBackend["start"]>> | undefined;
let backend: QemuBackend | undefined;

async function start(
  executable: string,
  args: string[],
  variables: Record<string, string>,
): Promise<void> {
  children.push(
    await processes.start({
      executable,
      args,
      environment: variables,
      directory: root,
    }),
  );
}

async function ready(url: string, attempts = 120): Promise<void> {
  if (failure !== undefined) {
    throw new Error("Workspace fixture failed", { cause: failure });
  }
  if (attempts === 0) {
    throw new Error(`Timed out waiting for ${url}`);
  }
  if (await httpReady(url, { timeoutMs: 1000 })) {
    return;
  }
  await delay(250);
  await ready(url, attempts - 1);
}

async function json(url: string, body: unknown): Promise<unknown> {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-CodeAPI-Internal-Token": internal,
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  assert.equal(response.ok, true, text);
  return JSON.parse(text);
}

const preparedSchema = z.object({
  payload: z.record(z.string(), z.unknown()),
  executionManifestClaims: z.record(z.string(), z.unknown()),
  egressGrantToken: z.string(),
});
const executionSchema = z.object({
  run: z.object({ code: z.number(), stdout: z.string(), stderr: z.string() }),
  files: z.array(z.object({ id: z.string(), name: z.string() })),
});

async function execute(
  script: string,
  input = false,
): Promise<z.infer<typeof executionSchema>> {
  assert.ok(guest);
  const inputFiles = input
    ? [
        {
          id: "i".repeat(21),
          storage_session_id: "s".repeat(21),
          name: "input.txt",
        },
      ]
    : [];
  const now = Math.floor(Date.now() / 1000);
  const prepared = preparedSchema.parse(
    await json(`http://127.0.0.1:${gatewayPort}/internal/egress-grants`, {
      payload: {
        language: "bash",
        version: configuration.bashVersion,
        session_id: "o".repeat(21),
        files: [{ name: "main.sh", content: script }, ...inputFiles],
        run_timeout: 30000,
      },
      claims: {
        v: 1,
        exec_id: randomUUID(),
        tenant_id: "fixture",
        user_id: "fixture",
        session_key: "tenant:fixture:user:fixture",
        input_files: inputFiles.map((file) => ({
          id: file.id,
          session_id: file.storage_session_id,
          name: file.name,
        })),
        read_sessions: input ? ["s".repeat(21)] : [],
        output_session_id: "o".repeat(21),
        max_upload_bytes: 1024 * 1024,
        max_output_files: 10,
        max_requests: 100,
        iat: now - 1,
        exp: now + 300,
        principal_source: "librechat",
        tool_call_socket: false,
        auth_context_hash: "fixture",
      },
    }),
  );
  const body = {
    ...prepared.payload,
    execution_manifest: signing.signExecutionManifestWithPrivateKey(
      {
        ...prepared.executionManifestClaims,
        execute_body_sha256: signing.executionManifestBodySha256(
          prepared.payload,
        ),
      },
      privateKey,
    ),
  };
  const response = await fetchSocket(
    guest.socket,
    new Request("http://guest/runner/api/v2/execute", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-runtime-session-id": session.runtimeId,
        "X-CodeAPI-Egress-Grant": prepared.egressGrantToken,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(90000),
    }),
  );
  const text = await response.text();
  assert.equal(response.ok, true, text);
  const result = executionSchema.parse(JSON.parse(text));
  assert.equal(result.run.code, 0, text);
  return result;
}

function quote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

try {
  await mkdir(join(root, "objects"));
  await writeFile(join(root, "object-key"), secret, { mode: 0o600 });
  await processes.run({
    executable: programs.iron,
    args: ["generate-ca", "--outdir", join(root, "iron")],
  });
  await start(
    programs.redis,
    [
      "--bind",
      "127.0.0.1",
      "--port",
      String(redisPort),
      "--requirepass",
      secret,
      "--save",
      "",
      "--appendonly",
      "no",
    ],
    {},
  );
  await start(programs.rustfs, ["server"], {
    RUSTFS_ADDRESS: `127.0.0.1:${objectPort}`,
    RUSTFS_CONSOLE_ADDRESS: `127.0.0.1:${consolePort}`,
    RUSTFS_CONSOLE_ENABLE: "false",
    RUSTFS_VOLUMES: join(root, "objects"),
    RUSTFS_ACCESS_KEY: "fixture",
    RUSTFS_SECRET_KEY_FILE: join(root, "object-key"),
  });
  const codeEnvironment = {
    REDIS_HOST: "127.0.0.1",
    REDIS_PORT: String(redisPort),
    REDIS_PASSWORD: secret,
    MINIO_ENDPOINT: "127.0.0.1",
    MINIO_PORT: String(objectPort),
    MINIO_USE_SSL: "false",
    MINIO_ACCESS_KEY: "fixture",
    MINIO_SECRET_KEY: secret,
    MINIO_BUCKET: "workspace-fixture",
    FILE_SERVER_HOST: "127.0.0.1",
    FILE_SERVER_PORT: String(filePort),
    FILE_SERVER_URL: `http://127.0.0.1:${filePort}`,
    TOOL_CALL_SERVER_URL: "http://127.0.0.1:1",
    EGRESS_GATEWAY_PORT: String(gatewayPort),
    CODEAPI_INTERNAL_SERVICE_TOKEN: internal,
    CODEAPI_EGRESS_GRANT_SECRET: "workspace-fixture-egress-secret-32-bytes",
  };
  const fileServer = await startFileServer(
    {
      command: {
        executable: programs.fileServer,
        args: [],
        environment: codeEnvironment,
        directory: root,
      },
      port: 0,
      token: internal,
    },
    { processes, signal: AbortSignal.timeout(120_000) },
  );
  children.push(fileServer.process);
  filePort = fileServer.port;
  codeEnvironment.FILE_SERVER_PORT = String(filePort);
  codeEnvironment.FILE_SERVER_URL = `http://127.0.0.1:${filePort}`;
  await start(programs.egressGateway, [], codeEnvironment);
  await ready(`http://127.0.0.1:${filePort}/ready`);
  await ready(`http://127.0.0.1:${gatewayPort}/ready`);
  backend = new QemuBackend({
    boot: {
      ironPort,
      fileRelayPort: gatewayPort,
      archiveBrokerPort: archivePort,
    },
    files,
    processes,
    fetch: async (socket, request) => {
      const response = await fetchSocket(socket, request);
      if (!response.ok) {
        console.error(
          new URL(request.url).pathname,
          await response.clone().text(),
        );
      }
      return response;
    },
    delay: async (milliseconds, signal) => {
      await delay(milliseconds, undefined, { signal });
    },
    timeout: (milliseconds) => AbortSignal.timeout(milliseconds),
    newBootId: randomUUID,
    caCertificate: await readFile(join(root, "iron/ca.crt"), "utf8"),
    archiveToken: "fixture-archive-token-32-bytes-long",
    executionPublicKey: publicKey,
    onFailure: async (_session, error) => {
      failure = error;
    },
    onError: (error) => {
      failure = error;
    },
  });
  guest = await backend.start(session, false);
  const upload = await fetch(
    `http://127.0.0.1:${filePort}/sessions/${"s".repeat(21)}/objects/${"i".repeat(21)}`,
    {
      method: "PUT",
      headers: {
        "X-CodeAPI-Internal-Token": internal,
        "X-Original-Filename": "input.txt",
        "content-type": "text/plain",
      },
      body: "input bytes\n",
    },
  );
  assert.equal(upload.ok, true, await upload.text());
  const first = await execute(
    "set -eu\ncat input.txt > /mnt/data/result.txt\n",
    true,
  );
  const artifact = first.files.find((file) => file.name === "result.txt");
  assert.ok(artifact, JSON.stringify(first));
  const download = await fetch(
    `http://127.0.0.1:${filePort}/sessions/${"o".repeat(21)}/objects/${artifact.id}`,
    { headers: { "X-CodeAPI-Internal-Token": internal } },
  );
  assert.deepEqual(
    { status: download.status, contents: await download.text() },
    { status: 200, contents: "input bytes\n" },
  );
  console.log("input and artefact transfer passed");
  const expression = `derivation { name = "workspace-built"; system = "${configuration.system}"; builder = builtins.storePath "${configuration.bash}"; PATH = "\${builtins.storePath "${configuration.coreutils}"}/bin"; args = [ "-c" "mkdir -p $out/bin; printf '#!${configuration.bash}\\nprintf built-ok\\n' > $out/bin/workspace-built; chmod +x $out/bin/workspace-built" ]; }`;
  const work = await execute(
    `set -eu\ntest "$HOME" = /work\ntest -f /work/.pki/nssdb/cert9.db\ncp /usr/bin/true /work/true\nchmod +x /work/true\n/work/true\ncp /usr/bin/true /mnt/data/true\nchmod +x /mnt/data/true\nif /mnt/data/true; then exit 1; fi\nrm /mnt/data/true\ncat /proc/sys/kernel/random/boot_id > /work/boot-id\nnix build --offline --impure --expr ${quote(expression)} --out-link /work/built\nnix profile add --offline "$(readlink -f /work/built)"\nworkspace-built\n`,
  );
  assert.equal(work.run.stdout, "built-ok");
  await backend.checkpoint(session, guest);
  await backend.stop(session, guest);
  guest = undefined;
  await delay(5000);
  guest = await backend.start(session, true);
  const restored = await execute(
    'set -eu\n/work/true\ntest "$(cat /work/boot-id)" = "$(cat /proc/sys/kernel/random/boot_id)"\nworkspace-built\ncat /mnt/data/result.txt\ndate +%s\n',
  );
  const lines = restored.run.stdout.trimEnd().split("\n");
  const clock = Number(lines.pop());
  assert.deepEqual(
    {
      contents: lines.join("\n"),
      clockClose: Math.abs(clock - Date.now() / 1000) < 5,
    },
    { contents: "built-okinput bytes", clockClose: true },
  );
  if (failure !== undefined) {
    throw new Error("Workspace fixture failed", { cause: failure });
  }
  console.log(
    "workspace execution, Nix build/profile, input/output transfer and full VM resume passed",
  );
} finally {
  if (guest !== undefined && backend !== undefined) {
    await backend.stop(session, guest);
  }
  await Promise.all(children.map(async (child) => child.stop()));
  await rm(root, { recursive: true, force: true });
}
