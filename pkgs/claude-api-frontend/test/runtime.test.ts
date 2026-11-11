import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import assert from "node:assert/strict";
import {
  CertificateCleanupError,
  CertificateCommandError,
} from "#frontend/errors";
import { X509Certificate } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import { certificates } from "#frontend/certificates";
import { configSchema, loadConfig, upstreamPort } from "#frontend/config";
import { checkHealth } from "#frontend/health";
import { NodeFrontendFiles } from "#frontend/files";
import {
  FakeTransport,
  FailingCertificateCommand,
  captureError,
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
      captureError(async () => await upstreamPort(config)),
    ).resolves.toStrictEqual(error);
  },
);

it("cleans up certificate staging after an injected command fails", async () => {
  const command = new FailingCertificateCommand();

  const result = await captureError(
    async () => await certificates(directory, command),
  );

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
    captureError(
      async () =>
        await checkHealth(config, {
          transport: stale,
          files: new NodeFrontendFiles(),
        }),
    ),
  ).resolves.toStrictEqual({
    data: {
      code: "invalid-config",
      source: "health",
      issues: [{ code: "invalid_value", path: ["account"] }],
    },
    cause: undefined,
  });
});

it("checks CA expiry using an injected clock before issuing a leaf certificate", async () => {
  const chain = await certificates(directory);
  const validTo = new X509Certificate(chain.ca).validTo;
  const result = await captureError(
    async () =>
      await certificates(directory, new FailingCertificateCommand(), {
        now: () => Date.parse(validTo) - 365 * 86400000,
        newSerial: () => "unused",
      }),
  );
  expect(result).toStrictEqual({
    data: { code: "certificate-expiring", validTo },
    cause: undefined,
  });
});

it("preserves configuration read failures through an injected file adapter", async () => {
  const cause = Object.assign(new Error("unreadable"), { code: "EACCES" });
  const files = {
    readText: async (_path: string): Promise<string> => {
      throw cause;
    },
  };
  const result = await captureError(
    async () => await loadConfig("/fixture/frontend.json", files),
  );
  expect(result).toStrictEqual({
    data: { code: "config-read", path: "/fixture/frontend.json" },
    cause,
  });
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
  let failure: unknown;
  try {
    await certificates(directory, command, {
      now: Date.now,
      newSerial: () => "unused",
      removeTemporary: async (_directory): Promise<void> => {
        throw cleanup;
      },
    });
  } catch (error) {
    failure = error;
  }
  assert.ok(failure instanceof CertificateCleanupError);
  assert.ok(failure.cause instanceof AggregateError);
  expect({ code: failure.code, failures: failure.cause.errors }).toStrictEqual({
    code: "certificate-cleanup",
    failures: [primary, cleanup],
  });
});
