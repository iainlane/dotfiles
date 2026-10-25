import { StatusCodes } from "http-status-codes";
import { beforeEach, expect, it } from "vitest";
import {
  ConversationRuntimeSupervisor,
  BridgeBodyDigestError,
  BridgeOwnerError,
  type ManifestClaims,
} from "./bridge.ts";
import { CODE_TENANT_ID, executionManifestPrincipal } from "./identity.ts";
import type { SessionLease } from "./sessions.ts";

const userId = "0123456789abcdef01234567";

const runtimeId = `rt_${"a".repeat(40)}`;

it("matches the opaque principal observed from the CodeAPI egress gateway", () => {
  expect(executionManifestPrincipal("6ade25fca20f1f42b68ec461")).toStrictEqual({
    user_id: "user:4PYroFHxlNaMqJf1v3d94ZRjg2iMV_NE",
    tenant_id: "tenant:xYa3je6WUsA_Ok13BhOZFL2TCETN7H2V",
  });
});

let claims: ManifestClaims;

let events: string[];

let supervisor: ConversationRuntimeSupervisor;

let onAcquire: (signal?: AbortSignal) => void;

beforeEach(() => {
  claims = {
    user_id: "user:iGX-qO22lxaawrT15jOeFkOTgQM2QO60",
    tenant_id: "tenant:xYa3je6WUsA_Ok13BhOZFL2TCETN7H2V",
    execute_body_sha256: "body-digest",
  };

  events = [];

  onAcquire = () => {};

  const lease: SessionLease = {
    session: {
      runtimeId,
      userId,
      conversationId: null,
      generation: 1,
      lastUsed: 0,
      checkpoint: false,
      expired: false,
      resetReason: "",
      quarantine: null,
    },
    guest: { socket: "/private/control", bootId: "boot" },
    release: async () => {
      events.push("release");
    },
  };

  supervisor = new ConversationRuntimeSupervisor({
    userId,
    sessions: {
      acquireCodeRuntime: async (id, signal) => {
        events.push(`acquire:${id}`);

        onAcquire(signal);

        return lease;
      },
      reset: async () => {
        events.push("reset");
      },
      quarantine: async () => {
        events.push("quarantine");
      },
    },
    fetch: async (_socket, request) => {
      events.push(
        `${request.method}:${new URL(request.url).pathname}:${request.headers.get("x-runtime-session-id")}:${request.headers.has("authorization")}`,
      );

      return new Response("result");
    },
    verifyManifest: () => claims,
    bodyDigest: () => "body-digest",
  });
});

it("uses the verified runtime lease and omits host credentials", async () => {
  const lease = await supervisor.acquire({
    runtimeSessionId: runtimeId,
    request: { body: { execution_manifest: "signed" } },
  });

  const response = await lease.execute({
    body: "{}",
    headers: {
      Authorization: "host-secret",
      "X-Runtime-Session-Id": "untrusted",
    },
  });

  await lease.release();

  expect({ response, events }).toStrictEqual({
    response: { status: StatusCodes.OK, body: "result" },
    events: [
      `acquire:${runtimeId}`,
      `POST:/runner/api/v2/execute:${runtimeId}:false`,
      "release",
    ],
  });
});

it.each([
  { user_id: "another-user" },
  { tenant_id: "another-tenant" },
  { user_id: userId },
  { tenant_id: CODE_TENANT_ID },
])(
  "rejects a different signed principal before creating a VM: %j",
  async (override) => {
    claims = { ...claims, ...override };

    await expect(
      supervisor.acquire({
        runtimeSessionId: runtimeId,
        request: { body: { execution_manifest: "signed" } },
      }),
    ).rejects.toThrow(BridgeOwnerError);

    expect(events).toStrictEqual([]);
  },
);

it("rejects a body digest mismatch before creating a VM", async () => {
  claims.execute_body_sha256 = "different";

  await expect(
    supervisor.acquire({
      runtimeSessionId: runtimeId,
      request: { body: { execution_manifest: "signed" } },
    }),
  ).rejects.toThrow(BridgeBodyDigestError);

  expect(events).toStrictEqual([]);
});

it.each(["before", "during"])(
  "rejects cancellation %s acquisition without leaking a lease",
  async (timing) => {
    const controller = new AbortController();

    const reason = new DOMException("Assignment cancelled", "AbortError");

    let receivedSignal: AbortSignal | undefined;

    onAcquire = (signal) => {
      receivedSignal = signal;

      controller.abort(reason);
    };

    if (timing === "before") {
      controller.abort(reason);
    }

    await expect(
      supervisor.acquire(
        {
          runtimeSessionId: runtimeId,
          request: { body: { execution_manifest: "signed" } },
        },
        controller.signal,
      ),
    ).rejects.toBe(reason);

    expect({ events, receivedSignal }).toStrictEqual({
      events: timing === "before" ? [] : [`acquire:${runtimeId}`, "release"],
      receivedSignal: timing === "before" ? undefined : controller.signal,
    });
  },
);
