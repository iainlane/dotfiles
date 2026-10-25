import { Client, credentials } from "@grpc/grpc-js";
import { loadSync } from "@grpc/proto-loader";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { expect, it } from "vitest";
import {
  credentialService,
  IronProtocolDefinitionError,
} from "./iron-service.ts";

it("serves credential transforms through a private Unix socket", async () => {
  const directory = await mkdtemp("/tmp/librechat-credentials-");

  const socket = join(directory, "transform.sock");
  const proto = join(directory, "transform.proto");

  await writeFile(
    proto,
    `
    syntax = "proto3";
    package transform.v1;
    message Request {}
    message Reply { int32 action = 1; }
    service TransformService {
      rpc TransformRequest(Request) returns (Reply);
      rpc TransformResponse(Request) returns (Reply);
    }
  `,
  );

  const definition = loadSync(proto);
  const service = definition["transform.v1.TransformService"];

  if (service === undefined || !("TransformRequest" in service)) {
    throw new IronProtocolDefinitionError();
  }

  const method = service.TransformRequest;

  if (method === undefined) {
    throw new IronProtocolDefinitionError();
  }

  let reads = 0;

  const server = await credentialService(
    proto,
    async () => {
      reads += 1;

      return "synthetic-token";
    },
    socket,
  );

  const client = new Client(`unix://${socket}`, credentials.createInsecure());

  try {
    const response = await new Promise<unknown>((resolve, reject) => {
      client.makeUnaryRequest(
        method.path,
        method.requestSerialize,
        method.responseDeserialize,
        {},
        (error, result) => {
          if (error !== null) {
            reject(error);

            return;
          }

          resolve(result);
        },
      );
    });

    const socketState = await stat(socket);
    const directoryState = await stat(directory);

    expect({
      socket: socketState.isSocket(),
      socketMode: socketState.mode & 0o777,
      directoryMode: directoryState.mode & 0o777,
      response,
      reads,
    }).toStrictEqual({
      socket: true,
      socketMode: 0o600,
      directoryMode: 0o700,
      response: { action: 2 },
      reads: 0,
    });
  } finally {
    client.close();

    server.forceShutdown();

    await rm(directory, { recursive: true, force: true });
  }
});
