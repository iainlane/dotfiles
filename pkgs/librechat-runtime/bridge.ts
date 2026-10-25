import { z } from "zod";
import {
  executionManifestPrincipal,
  type ManifestPrincipal,
} from "./identity.ts";
import type {
  Assignment,
  RuntimeLease,
  RuntimeSupervisor,
} from "./bridge-worker.mjs";
import type { SessionLease } from "./sessions.ts";
import type { SocketFetch } from "./http-socket.ts";

interface SessionAccess {
  acquireCodeRuntime(
    runtimeId: string,
    signal?: AbortSignal,
  ): Promise<SessionLease>;

  reset(runtimeId: string): Promise<void>;

  quarantine(runtimeId: string, reason: string): Promise<void>;
}

export interface ManifestClaims extends ManifestPrincipal {
  execute_body_sha256?: string;
}

interface BridgeOptions {
  userId: string;
  sessions: SessionAccess;
  fetch: SocketFetch;

  verifyManifest(token: string): ManifestClaims;

  bodyDigest(body: unknown): string;
}

export class BridgeAssignmentKindError extends Error {
  constructor() {
    super("This worker accepts only conversation-scoped code execution");

    this.name = "BridgeAssignmentKindError";
  }
}

export class BridgeRuntimeIdentityError extends Error {
  constructor() {
    super("The CodeAPI assignment requires a canonical runtime identity");

    this.name = "BridgeRuntimeIdentityError";
  }
}

export class BridgeManifestError extends Error {
  constructor(cause?: unknown) {
    super("The CodeAPI assignment has no valid signed execution manifest", {
      cause,
    });

    this.name = "BridgeManifestError";
  }
}

export class BridgeOwnerError extends Error {
  constructor() {
    super(
      "The signed CodeAPI assignment belongs to a different account or tenant",
    );

    this.name = "BridgeOwnerError";
  }
}

export class BridgeBodyDigestError extends Error {
  constructor() {
    super("The CodeAPI request body differs from its signed manifest");

    this.name = "BridgeBodyDigestError";
  }
}

const bodySchema = z.looseObject({ execution_manifest: z.string().min(1) });

export class ConversationRuntimeSupervisor implements RuntimeSupervisor {
  private readonly options: BridgeOptions;

  constructor(options: BridgeOptions) {
    this.options = options;
  }

  async acquire(
    assignment: Assignment,
    signal?: AbortSignal,
  ): Promise<RuntimeLease> {
    signal?.throwIfAborted();

    if (
      assignment.executionKind !== undefined &&
      assignment.executionKind !== "sandbox"
    ) {
      throw new BridgeAssignmentKindError();
    }

    const runtimeId = assignment.runtimeSessionId;

    if (runtimeId === undefined || !/^rt_[a-f0-9]{40}$/u.test(runtimeId)) {
      throw new BridgeRuntimeIdentityError();
    }

    const body = bodySchema.safeParse(assignment.request.body);

    if (!body.success) {
      throw new BridgeManifestError();
    }

    let claims: ManifestClaims;

    try {
      claims = this.options.verifyManifest(body.data.execution_manifest);
    } catch (cause) {
      throw new BridgeManifestError(cause);
    }

    const principal = executionManifestPrincipal(this.options.userId);

    if (
      claims.user_id !== principal.user_id ||
      claims.tenant_id !== principal.tenant_id
    ) {
      throw new BridgeOwnerError();
    }

    if (claims.execute_body_sha256 !== this.options.bodyDigest(body.data)) {
      throw new BridgeBodyDigestError();
    }

    const lease = await this.options.sessions.acquireCodeRuntime(
      runtimeId,
      signal,
    );

    if (signal?.aborted === true) {
      await lease.release();

      signal.throwIfAborted();
    }

    return {
      sessionId: runtimeId,
      release: () => lease.release(),
      execute: async (request) => {
        const headers = new Headers({
          "content-type": "application/json",
          "x-runtime-session-id": runtimeId,
        });

        for (const [name, value] of Object.entries(request.headers)) {
          if (
            ["x-codeapi-execution-manifest", "x-sandbox-egress-grant"].includes(
              name.toLowerCase(),
            )
          ) {
            headers.set(name, value);
          }
        }

        const response = await this.options.fetch(
          lease.guest.socket,
          new Request(
            `http://guest/runner${request.path ?? "/api/v2/execute"}`,
            {
              method: "POST",
              headers,
              body: request.body,
              signal: request.signal,
            },
          ),
        );

        return { status: response.status, body: await response.text() };
      },
    };
  }

  async reset(runtimeId: string): Promise<void> {
    await this.options.sessions.reset(runtimeId);
  }

  async quarantine(runtimeId: string, reason: string): Promise<void> {
    await this.options.sessions.quarantine(runtimeId, reason);
  }
}
