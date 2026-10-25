export interface Assignment {
  runtimeSessionId?: string;
  executionKind?: string;
  request: { body: object };
}

export interface ExecutionRequest {
  body: string;
  headers: Record<string, string>;
  path?: "/api/v2/execute" | "/api/v2/workspace/execute";
  signal?: AbortSignal;
}

export interface RuntimeLease {
  sessionId?: string;
  execute(request: ExecutionRequest): Promise<{ status: number; body: string }>;
  release(): Promise<void>;
}

export interface RuntimeSupervisor {
  acquire(assignment: Assignment, signal?: AbortSignal): Promise<RuntimeLease>;
  reset(runtimeSessionId: string, signal?: AbortSignal): Promise<void>;
  quarantine(
    runtimeSessionId: string,
    reason: string,
    cause?: unknown,
  ): Promise<void>;
}

export class BridgeWorker {
  constructor(options: {
    codeApiUrl: string;
    token: string;
    workerId: string;
    runtimeSupervisor: RuntimeSupervisor;
    capabilities: {
      statefulWorkspace: boolean;
      sandboxProfile: string;
      runtimes: string[];
    };
    onError(error: unknown): void;
  });
  run(signal?: AbortSignal): Promise<void>;
  resetWorkspace(runtimeSessionId: string, signal?: AbortSignal): Promise<void>;
}

export function verifyExecutionManifestWithPublicKey(
  token: string,
  publicKey: string,
): {
  user_id: string;
  tenant_id: string;
  session_key: string;
  execute_body_sha256?: string;
};

export function executionManifestBodySha256(body: unknown): string;
