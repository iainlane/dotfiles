import { StatusCodes } from "http-status-codes";
import type { BridgeAssignment } from "@dotfiles/librechat-code-bridge";
import { beforeEach, expect, it } from "vitest";
import {
  ConversationRuntimeSupervisor,
  BridgeBodyDigestError,
  BridgeOwnerError,
  type ManifestClaims,
} from "#runtime/codeapi/bridge";
import {
  CODE_TENANT_ID,
  executionManifestPrincipal,
} from "#runtime/platform/identity";
import type { SessionLease } from "#runtime/sessions/sessions";

const userId = "0123456789abcdef01234567";

const runtimeId = `rt_${"a".repeat(40)}`;

const assignment: BridgeAssignment = {
  protocolVersion: 1,
  assignmentId: "assignment",
  workerId: "worker",
  incarnationId: "incarnation",
  generation: 1,
  leaseToken: "lease",
  expiresAt: "2026-11-08T12:00:00Z",
  runtimeSessionId: runtimeId,
  request: { headers: {}, body: { execution_manifest: "signed" } },
};

it("matches the opaque principal observed from the CodeAPI egress gateway", () => {
  expect(executionManifestPrincipal("6ade25fca20f1f42b68ec461")).toStrictEqual({
    user_id: "user:4PYroFHxlNaMqJf1v3d94ZRjg2iMV_NE",
    tenant_id: "tenant:xYa3je6WUsA_Ok13BhOZFL2TCETN7H2V",
  });
});

class FixtureRuntimes {
  readonly vms = new Set<string>();
  readonly leases = new Set<SessionLease>();
  readonly requests: {
    socket: string;
    method: string;
    path: string;
    runtime: string | null;
    authorization: boolean;
  }[] = [];

  whileStarting: () => void = () => {};
  whenReady: () => void = () => {};

  async acquireCodeRuntime(
    id: string,
    signal?: AbortSignal,
  ): Promise<SessionLease> {
    this.whileStarting();
    signal?.throwIfAborted();
    this.vms.add(id);
    this.whenReady();

    const lease: SessionLease = {
      session: {
        runtimeId: id,
        userId,
        conversationId: null,
        generation: 1,
        lastUsed: 0,
        checkpoint: false,
        expired: false,
        resetReason: "",
        quarantine: null,
      },
      guest: { socket: `/private/${id}`, bootId: "boot" },
      release: async () => {
        this.leases.delete(lease);
      },
    };

    this.leases.add(lease);

    return lease;
  }

  async reset(id: string): Promise<void> {
    this.vms.delete(id);
  }

  async quarantine(id: string): Promise<void> {
    this.vms.delete(id);
  }

  async fetch(socket: string, request: Request): Promise<Response> {
    this.requests.push({
      socket,
      method: request.method,
      path: new URL(request.url).pathname,
      runtime: request.headers.get("x-runtime-session-id"),
      authorization: request.headers.has("authorization"),
    });

    return new Response("result");
  }

  state() {
    return {
      vms: [...this.vms],
      leases: [...this.leases].map((lease) => lease.session.runtimeId),
      requests: this.requests,
    };
  }
}

let claims: ManifestClaims;

let runtimes: FixtureRuntimes;

let supervisor: ConversationRuntimeSupervisor;

beforeEach(() => {
  claims = {
    user_id: "user:iGX-qO22lxaawrT15jOeFkOTgQM2QO60",
    tenant_id: "tenant:xYa3je6WUsA_Ok13BhOZFL2TCETN7H2V",
    execute_body_sha256: "body-digest",
  };

  runtimes = new FixtureRuntimes();

  supervisor = new ConversationRuntimeSupervisor({
    userId,
    sessions: runtimes,
    fetch: async (socket, request) => await runtimes.fetch(socket, request),
    verifyManifest: () => claims,
    bodyDigest: () => "body-digest",
  });
});

it("uses the verified runtime lease and omits host credentials", async () => {
  const lease = await supervisor.acquire(assignment);

  const response = await lease.execute({
    body: "{}",
    headers: {
      Authorization: "host-secret",
      "X-Runtime-Session-Id": "untrusted",
    },
  });

  const leased = runtimes.state().leases;

  await lease.release();

  expect({ response, leased, runtimes: runtimes.state() }).toStrictEqual({
    response: { status: StatusCodes.OK, body: "result" },
    leased: [runtimeId],
    runtimes: {
      vms: [runtimeId],
      leases: [],
      requests: [
        {
          socket: `/private/${runtimeId}`,
          method: "POST",
          path: "/runner/api/v2/execute",
          runtime: runtimeId,
          authorization: false,
        },
      ],
    },
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

    await expect(supervisor.acquire(assignment)).rejects.toStrictEqual(
      new BridgeOwnerError(),
    );

    expect(runtimes.state()).toStrictEqual({
      vms: [],
      leases: [],
      requests: [],
    });
  },
);

it("rejects a body digest mismatch before creating a VM", async () => {
  claims.execute_body_sha256 = "different";

  await expect(supervisor.acquire(assignment)).rejects.toStrictEqual(
    new BridgeBodyDigestError(),
  );

  expect(runtimes.state()).toStrictEqual({
    vms: [],
    leases: [],
    requests: [],
  });
});

it.each([
  { timing: "before acquisition", vms: [] },
  { timing: "while the VM starts", vms: [] },
  { timing: "after the VM is ready", vms: [runtimeId] },
])(
  "rejects cancellation $timing without leaking a lease",
  async ({ timing, vms }) => {
    const controller = new AbortController();

    const cancel = () => {
      controller.abort(new DOMException("Assignment cancelled", "AbortError"));
    };

    if (timing === "before acquisition") {
      cancel();
    }

    if (timing === "while the VM starts") {
      runtimes.whileStarting = cancel;
    }

    if (timing === "after the VM is ready") {
      runtimes.whenReady = cancel;
    }

    await expect(
      supervisor.acquire(assignment, controller.signal),
    ).rejects.toStrictEqual(
      new DOMException("Assignment cancelled", "AbortError"),
    );

    expect(runtimes.state()).toStrictEqual({ vms, leases: [], requests: [] });
  },
);
