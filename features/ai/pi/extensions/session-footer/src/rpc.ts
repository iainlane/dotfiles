import { randomUUID } from "node:crypto";
import { record, text } from "./text.ts";

export interface FooterBus {
  on(event: string, handler: (value: unknown) => void): () => void;
  emit(event: string, value: unknown): void;
}

export interface RpcFailure {
  kind: "timeout" | "remote" | "malformed" | "transport" | "disposed";
  message: string;
}

export type RpcResult =
  { ok: true; data: unknown } | { ok: false; error: RpcFailure };

function failure(kind: RpcFailure["kind"], message: string): RpcResult {
  return { ok: false, error: { kind, message } };
}

function decodeReply(raw: unknown, requestId: string): RpcResult | undefined {
  if (record(raw) && raw.requestId !== requestId) return undefined;

  if (
    !record(raw) ||
    raw.version !== 1 ||
    (raw.success !== true && raw.success !== false)
  )
    return failure("malformed", "Invalid RPC reply");

  if (raw.success) return { ok: true, data: raw.data };

  const error = record(raw.error) ? raw.error : {};
  const message = [text(error.code), text(error.message)]
    .filter(Boolean)
    .join(": ");

  return failure("remote", text(message, 240) || "RPC request failed");
}

export class RpcClient {
  private pending:
    { method: "status" | "cost"; promise: Promise<RpcResult> } | undefined;
  private cancel: (() => void) | undefined;
  private disposed = false;

  constructor(private readonly bus: FooterBus) {}

  request(method: "status" | "cost"): Promise<RpcResult> {
    if (this.disposed)
      return Promise.resolve(failure("disposed", "RPC client disposed"));

    if (this.pending)
      return this.pending.method === method
        ? this.pending.promise
        : this.pending.promise.then(() => this.request(method));

    const requestId = randomUUID();
    const promise = new Promise<RpcResult>((resolve) => {
      let settled = false;
      let unsubscribe = () => {};
      let timer: ReturnType<typeof setTimeout> | undefined;

      const finish = (value: RpcResult) => {
        if (settled) return;

        settled = true;

        if (timer) clearTimeout(timer);

        unsubscribe();
        this.cancel = undefined;
        resolve(value);
      };

      this.cancel = () => finish(failure("disposed", "RPC client disposed"));

      try {
        unsubscribe = this.bus.on(
          `subagents:rpc:v1:reply:${requestId}`,
          (raw) => {
            const reply = decodeReply(raw, requestId);

            if (reply) finish(reply);
          },
        );
        timer = setTimeout(
          () => finish(failure("timeout", `RPC ${method} timed out`)),
          2000,
        );

        this.bus.emit("subagents:rpc:v1:request", {
          version: 1,
          requestId,
          method,
          source: { extension: "session-footer" },
        });
      } catch (error) {
        finish(
          failure(
            "transport",
            text(error instanceof Error ? error.message : error) ||
              "RPC transport failed",
          ),
        );
      }
    });

    this.pending = { method, promise };

    void promise.finally(() => {
      if (this.pending?.promise === promise) this.pending = undefined;
    });

    return promise;
  }

  dispose(): void {
    this.disposed = true;

    this.cancel?.();
  }
}
