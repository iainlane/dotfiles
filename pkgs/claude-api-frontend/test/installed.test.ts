import { spawn, execFile } from "node:child_process";
import http from "node:http";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import tls from "node:tls";
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";
import { expect, it } from "vitest";
import { UnexpectedListenerError } from "#frontend/errors";
import {
  FrontendEarlyExitError,
  FrontendStartupTimeoutError,
} from "./fakes.ts";

const execute = promisify(execFile);

type ProcessOutcome =
  | { kind: "exited"; code: number | null }
  | { kind: "spawn-failed"; error: Error };

async function earlyExit(
  exited: Promise<ProcessOutcome>,
  stderr: () => string,
): Promise<never> {
  const outcome = await exited;
  if (outcome.kind === "spawn-failed") {
    throw outcome.error;
  }
  throw new FrontendEarlyExitError(outcome.code, stderr());
}

async function startupDeadline(stderr: () => string): Promise<never> {
  await delay(20000, undefined, { ref: false });
  throw new FrontendStartupTimeoutError(stderr());
}

async function listen(server: http.Server): Promise<number> {
  await new Promise<void>((ready) => {
    server.listen(0, "127.0.0.1", ready);
  });
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new UnexpectedListenerError();
  }
  return address.port;
}

async function close(server: http.Server): Promise<void> {
  server.closeAllConnections();
  await new Promise<void>((done) => {
    server.close(() => done());
  });
}

interface InstalledResources {
  directory: string;
  upstream: http.Server;
}

async function exerciseInstalledFrontend(
  options: {
    program?: string;
    observe?: (resources: InstalledResources) => void;
  } = {},
): Promise<{
  response: object;
  diagnostics: { stderr: string; tokenLogged: boolean; bodyLogged: boolean };
}> {
  const directory = await mkdtemp(join(tmpdir(), "frontend-installed-"));
  const upstream = http.createServer();
  options.observe?.({ directory, upstream });
  const probe = http.createServer();
  const upstreamPort = await listen(upstream);
  const port = await listen(probe);
  await close(probe);
  const config = join(directory, "frontend.json");
  const teamclaude = join(directory, "teamclaude.json");
  await writeFile(
    teamclaude,
    JSON.stringify({ proxy: { port: upstreamPort } }),
  );
  await writeFile(
    config,
    JSON.stringify({
      port,
      teamclaudeConfigFile: teamclaude,
      stateDirectory: directory,
      account: "fixture account",
    }),
  );

  const installed = process.env.CLAUDE_API_FRONTEND_PROGRAM;
  const program = options.program ?? installed ?? process.execPath;
  const prefix =
    installed === undefined
      ? [resolve(import.meta.dirname, "../src/cli.ts")]
      : [];
  const environment = {
    ...process.env,
    ...(installed === undefined ? {} : { PATH: "" }),
    NODE_PATH: "",
  };
  const child = spawn(program, [...prefix, "serve", "--config", config], {
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  const exited = new Promise<ProcessOutcome>((done) => {
    child.once("exit", (code) => done({ kind: "exited", code }));
    child.once("error", (error) => done({ kind: "spawn-failed", error }));
  });
  const listening = new Promise<void>((ready) => {
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      if (stdout.includes('"event":"listening"')) {
        ready();
      }
    });
  });
  child.stderr.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });
  let socket: tls.TLSSocket | undefined;

  try {
    await Promise.race([
      listening,
      earlyExit(exited, () => stderr),
      startupDeadline(() => stderr),
    ]);
    const received = new Promise<{
      request: {
        url: string | undefined;
        method: string | undefined;
        headers: http.IncomingHttpHeaders;
        body: string;
      };
      response: http.ServerResponse;
    }>((done) => {
      upstream.on("request", (request, response) => {
        if (request.url === "/teamclaude/dashboard") {
          response.end("dashboard");
          return;
        }
        const chunks: Buffer[] = [];
        request.on("data", (chunk: Buffer) => chunks.push(chunk));
        request.on("end", () => {
          response.writeHead(200, {
            "content-type": "text/event-stream",
            "x-fixture": "preserved",
          });
          response.write("data: first\n\n");
          done({
            request: {
              url: request.url,
              method: request.method,
              headers: request.headers,
              body: Buffer.concat(chunks).toString(),
            },
            response,
          });
        });
      });
    });
    expect(
      await execute(program, [...prefix, "check", "--config", config], {
        env: environment,
      }),
    ).toStrictEqual({ stdout: "", stderr: "" });
    const ca = await readFile(join(directory, "authority/ca.pem"));
    const connection = await new Promise<tls.TLSSocket>((done, reject) => {
      const request = http.request({
        host: "127.0.0.1",
        port,
        method: "CONNECT",
        path: "api.anthropic.com:443",
        signal: AbortSignal.timeout(10000),
      });
      request.once("error", reject);
      request.once("connect", (_response, tunnel) => {
        const secure = tls.connect(
          {
            socket: tunnel,
            servername: "api.anthropic.com",
            ca,
            ALPNProtocols: ["http/1.1"],
          },
          () => done(secure),
        );
        secure.once("error", reject);
      });
      request.end();
    });
    socket = connection;
    const body = JSON.stringify({
      system: "x-anthropic-billing-header: private\nKeep.",
      messages: [],
    });
    const first = Promise.withResolvers<string>();
    const result = new Promise<object>((done, reject) => {
      const request = http.request(
        {
          host: "api.anthropic.com",
          path: "/v1/messages?beta=true",
          method: "POST",
          headers: {
            "user-agent": "claude-cli/2.1.310 (external, cli)",
            "anthropic-beta": "claude-code-20250219,other-beta",
            "content-length": String(Buffer.byteLength(body)),
            authorization: "Bearer fixture-private-token",
          },
          createConnection: () => connection,
          signal: AbortSignal.timeout(10000),
        },
        (response) => {
          const chunks: Buffer[] = [];
          response.once("data", (chunk: Buffer) =>
            first.resolve(chunk.toString()),
          );
          response.on("data", (chunk: Buffer) => chunks.push(chunk));
          response.once("end", () =>
            done({
              status: response.statusCode,
              contentType: response.headers["content-type"],
              marker: response.headers["x-fixture"],
              body: Buffer.concat(chunks).toString(),
            }),
          );
          response.once("error", reject);
        },
      );
      request.once("error", reject);
      request.end(body);
    });
    const verifyStream = async (): Promise<void> => {
      expect(await first.promise).toBe("data: first\n\n");
      const captured = await received;
      const converted = JSON.stringify({ system: "Keep.", messages: [] });
      expect(captured.request).toStrictEqual({
        url: "/tc-acct/fixture%20account/v1/messages?beta=true",
        method: "POST",
        headers: {
          host: `127.0.0.1:${upstreamPort}`,
          connection: "keep-alive",
          "user-agent": "claude-cli/2.1.310 (external, sdk-cli)",
          "anthropic-beta": "other-beta",
          "content-length": String(Buffer.byteLength(converted)),
          authorization: "Bearer fixture-private-token",
          accept: "*/*",
          "accept-language": "*",
          "sec-fetch-mode": "cors",
          "accept-encoding": "gzip, deflate",
        },
        body: converted,
      });
      captured.response.end("data: second\n\n");
    };
    const [response] = await Promise.all([result, verifyStream()]);
    return {
      response,
      diagnostics: {
        stderr,
        tokenLogged: stdout.includes("fixture-private-token"),
        bodyLogged: stdout.includes("billing-header"),
      },
    };
  } finally {
    socket?.destroy();
    child.kill("SIGTERM");
    await Promise.race([exited, delay(5000, undefined, { ref: false })]);
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
    }
    await exited;
    await close(upstream);
    await rm(directory, { recursive: true, force: true });
  }
}

it("serves an inference request through the executable with its packaged dependencies", async () => {
  expect(await exerciseInstalledFrontend()).toStrictEqual({
    response: {
      status: 200,
      contentType: "text/event-stream",
      marker: "preserved",
      body: "data: first\n\ndata: second\n\n",
    },
    diagnostics: { stderr: "", tokenLogged: false, bodyLogged: false },
  });
});

it("cleans up the installed fixture and preserves the error when its executable cannot start", async () => {
  let resources: InstalledResources | undefined;
  const program = join(tmpdir(), "missing-frontend-executable", "frontend");
  try {
    await expect(
      exerciseInstalledFrontend({
        program,
        observe: (opened) => {
          resources = opened;
        },
      }),
    ).rejects.toMatchObject({ code: "ENOENT", path: program });
    assert.ok(resources !== undefined);
    expect(resources.upstream.listening).toBe(false);
    await expect(access(resources.directory)).rejects.toMatchObject({
      code: "ENOENT",
    });
  } finally {
    if (resources !== undefined) {
      await close(resources.upstream);
      await rm(resources.directory, { recursive: true, force: true });
    }
  }
});
