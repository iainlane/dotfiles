import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import {
  CertificateCleanupError,
  CertificateCommandError,
  CertificateExpiringError,
  ConfigurationReadError,
  InvalidConfigurationError,
  LoopbackDisabledError,
  PortConflictError,
} from "#frontend/errors";
import { X509Certificate } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { certificates } from "#frontend/certificates";
import { loadConfig, upstreamPort } from "#frontend/config";
import { checkHealth } from "#frontend/health";
import { NodeFrontendFiles } from "#frontend/files";
import {
  FakeTransport,
  FailingCertificateCommand,
  frontendConfig,
} from "./fakes.ts";

let directory: string;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "claude-api-frontend-runtime-"));
});

afterEach(async () => {
  vi.unstubAllEnvs();
  await rm(directory, { recursive: true, force: true });
});

it("loads defaults and the runtime TeamClaude port without copying credentials", async () => {
  const configFile = join(directory, "frontend.json");
  const teamclaudeConfigFile = join(directory, "teamclaude.json");

  await writeFile(
    configFile,
    JSON.stringify({ teamclaudeConfigFile, stateDirectory: directory }),
  );
  await writeFile(
    teamclaudeConfigFile,
    JSON.stringify({
      proxy: { port: 7777, apiKey: "private" },
      accounts: [{ apiKey: "private" }],
    }),
  );

  const config = await loadConfig(configFile);

  expect({ config, port: await upstreamPort(config) }).toStrictEqual({
    config: {
      port: 3457,
      teamclaudeConfigFile,
      stateDirectory: directory,
      account: null,
      maxBodyBytes: 33554432,
      timeoutMs: 300000,
    },
    port: 7777,
  });
});

it.each([
  { proxy: { trustLoopback: false }, error: new LoopbackDisabledError() },
  { proxy: { port: 3457 }, error: new PortConflictError(3457) },
])(
  "rejects incompatible TeamClaude configuration: $proxy",
  async ({ proxy, error }) => {
    const teamclaudeConfigFile = join(directory, "teamclaude.json");

    await writeFile(teamclaudeConfigFile, JSON.stringify({ proxy }));

    const config = await frontendConfig({
      teamclaudeConfigFile,
      stateDirectory: directory,
    });

    await expect(upstreamPort(config)).rejects.toStrictEqual(error);
  },
);

it("cleans up certificate staging after an injected command fails", async () => {
  const command = new FailingCertificateCommand();

  await expect(certificates(directory, command)).rejects.toStrictEqual(
    new CertificateCommandError({ cause: { code: "FAKE_OPENSSL_FAILURE" } }),
  );
  expect(await readdir(directory)).toStrictEqual([]);
});

it("checks the running certificate, account and upstream through an injected transport", async () => {
  const chain = await certificates(directory);
  const teamclaudeConfigFile = join(directory, "teamclaude.json");

  await writeFile(
    teamclaudeConfigFile,
    JSON.stringify({ proxy: { port: 3456 } }),
  );

  const config = await frontendConfig({
    teamclaudeConfigFile,
    stateDirectory: directory,
    account: "anthropic",
  });
  const fingerprint = new X509Certificate(chain.ca).fingerprint256;
  const transport = new FakeTransport((request) =>
    request.url.endsWith("/health")
      ? Response.json({ fingerprint, upstreamPort: 3456, account: "anthropic" })
      : new Response("dashboard"),
  );

  await checkHealth(config, { transport, files: new NodeFrontendFiles() });

  expect(await transport.snapshot()).toStrictEqual([
    {
      url: "http://127.0.0.1:3457/_claude-api-frontend/health",
      method: "GET",
      headers: {},
      body: "",
    },
    {
      url: "http://127.0.0.1:3456/teamclaude/dashboard",
      method: "GET",
      headers: {},
      body: "",
    },
  ]);

  const stale = new FakeTransport(() =>
    Response.json({ fingerprint, upstreamPort: 3456, account: "old-account" }),
  );

  await expect(
    checkHealth(config, { transport: stale, files: new NodeFrontendFiles() }),
  ).rejects.toStrictEqual(
    new InvalidConfigurationError("health", [
      { code: "invalid_value", path: ["account"] },
    ]),
  );
});

it("issues SHA-256 certificates whatever the host's OPENSSL_CONF contains", async () => {
  const configuration = join(directory, "openssl.cnf");

  await writeFile(
    configuration,
    [
      "openssl_conf = init",
      "[init]",
      "providers = providers",
      "[providers]",
      "null = null_provider",
      "[null_provider]",
      "activate = 1",
      "[req]",
      "default_md = sha1",
      "",
    ].join("\n"),
  );
  vi.stubEnv("OPENSSL_CONF", configuration);

  const chain = await certificates(join(directory, "state"));

  expect({
    ca: new X509Certificate(chain.ca).signatureAlgorithm,
    leaf: new X509Certificate(chain.cert).signatureAlgorithm,
  }).toStrictEqual({
    ca: "ecdsa-with-SHA256",
    leaf: "ecdsa-with-SHA256",
  });
});

it("checks CA expiry using an injected clock before issuing a leaf certificate", async () => {
  const chain = await certificates(directory);
  const validTo = new X509Certificate(chain.ca).validTo;
  await expect(
    certificates(directory, new FailingCertificateCommand(), {
      now: () => Date.parse(validTo) - 365 * 86400000,
      newSerial: () => "unused",
    }),
  ).rejects.toStrictEqual(new CertificateExpiringError(validTo));
});

it("preserves configuration read failures through an injected file adapter", async () => {
  const cause = Object.assign(new Error("unreadable"), { code: "EACCES" });
  const files = {
    readText: async (_path: string): Promise<string> => {
      throw cause;
    },
  };
  await expect(
    loadConfig("/fixture/frontend.json", files),
  ).rejects.toStrictEqual(
    new ConfigurationReadError("/fixture/frontend.json", { cause }),
  );
});

it("retains certificate generation and cleanup failures together", async () => {
  const primary = new CertificateCommandError({
    cause: { code: "OPENSSL_FAILURE" },
  });
  const cleanup = Object.assign(new Error("cleanup denied"), {
    code: "EACCES",
  });
  const command = {
    run: async (_arguments: readonly string[]): Promise<void> => {
      throw primary;
    },
  };

  await expect(
    certificates(directory, command, {
      now: Date.now,
      newSerial: () => "unused",
      removeTemporary: async (_directory): Promise<void> => {
        throw cleanup;
      },
    }),
  ).rejects.toStrictEqual(new CertificateCleanupError(primary, cleanup));
});
