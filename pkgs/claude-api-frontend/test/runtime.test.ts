import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { X509Certificate } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import { certificates } from "../src/certificates.ts";
import { configSchema, loadConfig, upstreamPort } from "../src/config.ts";
import { checkHealth } from "../src/health.ts";
import {
  FakeTransport,
  FailingCertificateCommand,
  errorSnapshot,
} from "./fakes.ts";

let directory: string;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "claude-api-frontend-runtime-"));
});

afterEach(async () => {
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
  {
    proxy: { trustLoopback: false },
    error: { data: { code: "loopback-disabled" }, cause: undefined },
  },
  {
    proxy: { port: 3457 },
    error: { data: { code: "port-conflict", port: 3457 }, cause: undefined },
  },
])(
  "rejects incompatible TeamClaude configuration: $proxy",
  async ({ proxy, error }) => {
    const teamclaudeConfigFile = join(directory, "teamclaude.json");

    await writeFile(teamclaudeConfigFile, JSON.stringify({ proxy }));

    const config = configSchema.parse({
      teamclaudeConfigFile,
      stateDirectory: directory,
    });

    await expect(
      upstreamPort(config).catch(errorSnapshot),
    ).resolves.toStrictEqual(error);
  },
);

it("cleans up certificate staging after an injected command fails", async () => {
  const command = new FailingCertificateCommand();

  const result = await certificates(directory, command).catch(errorSnapshot);

  expect({ error: result, files: await readdir(directory) }).toStrictEqual({
    error: {
      data: { code: "certificate-command" },
      cause: { code: "FAKE_OPENSSL_FAILURE" },
    },
    files: [],
  });
});

it("checks the running certificate, account and upstream through an injected transport", async () => {
  const chain = await certificates(directory);
  const teamclaudeConfigFile = join(directory, "teamclaude.json");

  await writeFile(
    teamclaudeConfigFile,
    JSON.stringify({ proxy: { port: 3456 } }),
  );

  const config = configSchema.parse({
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

  await checkHealth(config, transport);

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
    checkHealth(config, stale).catch(errorSnapshot),
  ).resolves.toStrictEqual({
    data: {
      code: "invalid-config",
      source: "health",
      issues: [{ code: "invalid_value", path: ["account"] }],
    },
    cause: undefined,
  });
});
