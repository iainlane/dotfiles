import {
  status as GrpcStatus,
  Server,
  ServerCredentials,
  type ServerUnaryCall,
  type sendUnaryData,
  type ServiceDefinition,
  type UntypedServiceImplementation,
} from "@grpc/grpc-js";
import { loadSync } from "@grpc/proto-loader";
import { rm, chmod } from "node:fs/promises";
import { callbackify } from "node:util";
import { StatusCodes } from "http-status-codes";
import {
  GithubCredentialTransform,
  transformRequestSchema,
} from "./github-credentials.ts";

export class IronProtocolDefinitionError extends Error {
  constructor() {
    super(
      "The pinned Iron protocol does not define the credential transform service",
    );

    this.name = "IronProtocolDefinitionError";
  }
}

function isService(value: unknown): value is ServiceDefinition {
  return (
    typeof value === "object" &&
    value !== null &&
    "TransformRequest" in value &&
    "TransformResponse" in value
  );
}

export async function credentialService(
  proto: string,
  readToken: () => Promise<string>,
  socketPath: string,
): Promise<Server> {
  const definition = loadSync(proto, { keepCase: false, defaults: true });

  const service = definition["transform.v1.TransformService"];

  if (!isService(service)) {
    throw new IronProtocolDefinitionError();
  }

  const transform = new GithubCredentialTransform(readToken);

  const handle = callbackify(async (raw: unknown): Promise<object> => {
    const input = transformRequestSchema.safeParse(raw);

    if (!input.success) {
      return {
        action: 2,
        response: {
          statusCode: StatusCodes.BAD_REQUEST,
          body: Buffer.from("Invalid transform request"),
        },
      };
    }

    return await transform.request(input.data).catch(() => ({
      action: 2,
      response: {
        statusCode: StatusCodes.BAD_GATEWAY,
        body: Buffer.from("Credential transform unavailable"),
      },
    }));
  });

  const implementation: UntypedServiceImplementation = {
    TransformRequest: (
      call: ServerUnaryCall<unknown, unknown>,
      callback: sendUnaryData<unknown>,
    ) =>
      handle(call.request, (error, result) => {
        if (error !== null) {
          callback({
            code: GrpcStatus.INTERNAL,
            details: "Credential transform unavailable",
          });

          return;
        }

        callback(null, result);
      }),
    TransformResponse: (
      _call: ServerUnaryCall<unknown, unknown>,
      callback: sendUnaryData<unknown>,
    ) => callback(null, { action: 1 }),
  };

  const server = new Server();

  server.addService(service, implementation);

  await rm(socketPath, { force: true });

  await new Promise<void>((resolve, reject) => {
    server.bindAsync(
      `unix://${socketPath}`,
      ServerCredentials.createInsecure(),
      (error) => {
        if (error !== null) {
          reject(error);

          return;
        }

        resolve();
      },
    );
  });

  await chmod(socketPath, 0o600);

  return server;
}

export function ironConfiguration(
  directory: string,
  hostAddresses: string[],
  credentialSocket: string,
): object {
  return {
    dns: { enabled: false },
    proxy: {
      http_listen: "127.0.0.1:0",
      https_listen: "127.0.0.1:0",
      tunnel_listen: "127.0.0.1:3128",
      upstream_deny_cidrs: [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.0.0.0/24",
        "192.0.2.0/24",
        "192.88.99.0/24",
        "192.168.0.0/16",
        "198.18.0.0/15",
        "198.51.100.0/24",
        "203.0.113.0/24",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "::/0",
        ...hostAddresses,
      ],
    },
    tls: {
      mode: "mitm",
      ca_cert: `${directory}/ca.crt`,
      ca_key: `${directory}/ca.key`,
    },
    metrics: { listen: "127.0.0.1:0" },
    transforms: [
      { name: "allowlist", config: { domains: ["*"] } },
      {
        name: "grpc",
        config: {
          name: "github-credentials",
          target: `unix://${credentialSocket}`,
          send_request_body: false,
          send_response_body: false,
        },
      },
    ],
  };
}
