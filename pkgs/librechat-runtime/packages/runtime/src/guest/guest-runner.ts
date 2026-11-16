import { StatusCodes } from "http-status-codes";
import { createConnection, type Socket } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import { sendHttpRequest } from "#runtime/http/http-socket";

const attempts = 30;

const interval = 1000;

export class GuestRunnerStartupError extends Error {
  constructor() {
    super("The guest execution runner did not become ready");

    this.name = "GuestRunnerStartupError";
  }
}

export class GuestRunnerUnavailableError extends Error {
  readonly status = StatusCodes.SERVICE_UNAVAILABLE;

  constructor(cause: unknown) {
    super("The guest execution runner is not accepting connections", {
      cause,
    });

    this.name = "GuestRunnerUnavailableError";
  }
}

export class GuestRunnerConnectionError extends Error {
  readonly status = StatusCodes.BAD_GATEWAY;

  constructor(cause: unknown) {
    super(
      "The connection to the guest execution runner failed after the request was sent",
      { cause },
    );

    this.name = "GuestRunnerConnectionError";
  }
}

interface GuestRunnerDependencies {
  connect(): Socket;

  pause(milliseconds: number, signal?: AbortSignal): Promise<void>;

  timeout(milliseconds: number): AbortSignal;
}

/**
 * Sends requests to the execution runner in the guest. Each request opens a
 * new connection, so a connection that the runner closed while the VM was
 * checkpointed is never reused. A refused connection is retried for a bounded
 * time. Once the runner has accepted the connection, the request is sent once
 * and its failure is reported, because the runner may already have acted on
 * it.
 */
export class GuestRunner {
  private readonly dependencies: GuestRunnerDependencies;

  constructor(dependencies: GuestRunnerDependencies) {
    this.dependencies = dependencies;
  }

  static local(): GuestRunner {
    return new GuestRunner({
      connect: () => createConnection({ host: "127.0.0.1", port: 2000 }),
      pause: async (milliseconds, signal) => {
        await delay(milliseconds, undefined, { signal });
      },
      timeout: (milliseconds) => AbortSignal.timeout(milliseconds),
    });
  }

  async request(request: Request): Promise<Response> {
    const socket = await this.connect(request.signal);

    return await this.send(socket, request);
  }

  async waitUntilReady(running: () => boolean): Promise<void> {
    await this.poll(running, attempts);
  }

  private async poll(running: () => boolean, remaining: number): Promise<void> {
    if (remaining === 0 || !running()) {
      throw new GuestRunnerStartupError();
    }

    if (await this.healthy()) {
      return;
    }

    await this.dependencies.pause(interval);

    await this.poll(running, remaining - 1);
  }

  private async healthy(): Promise<boolean> {
    const signal = this.dependencies.timeout(interval);

    try {
      const response = await this.send(
        await this.open(signal),
        new Request("http://runner/api/v2/health", { signal }),
      );

      await response.body?.cancel();

      return response.ok;
    } catch {
      return false;
    }
  }

  private async connect(signal: AbortSignal, attempt = 1): Promise<Socket> {
    signal.throwIfAborted();

    try {
      return await this.open(signal);
    } catch (cause) {
      signal.throwIfAborted();

      if (attempt === attempts) {
        throw new GuestRunnerUnavailableError(cause);
      }
    }

    await this.dependencies.pause(interval, signal);

    return await this.connect(signal, attempt + 1);
  }

  private async open(signal: AbortSignal): Promise<Socket> {
    signal.throwIfAborted();

    const socket = this.dependencies.connect();

    await new Promise<void>((resolve, reject) => {
      const abort = (): void => {
        const reason: unknown = signal.reason;

        socket.destroy(
          reason instanceof Error
            ? reason
            : new DOMException("This operation was aborted", {
                name: "AbortError",
                cause: reason,
              }),
        );
      };

      const fail = (error: Error): void => {
        signal.removeEventListener("abort", abort);
        reject(error);
      };

      signal.addEventListener("abort", abort, { once: true });
      socket.once("error", fail);
      socket.once("connect", () => {
        socket.off("error", fail);
        signal.removeEventListener("abort", abort);
        resolve();
      });
    });

    return socket;
  }

  private async send(socket: Socket, request: Request): Promise<Response> {
    return await sendHttpRequest(
      { createConnection: () => socket },
      request,
      (cause) => new GuestRunnerConnectionError(cause),
    );
  }
}
