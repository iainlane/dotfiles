import { basename } from "node:path";
import {
  errorDiagnostic,
  redactDiagnostic,
} from "@dotfiles/librechat-runtime/diagnostics";
import type { ProcessOutput } from "@dotfiles/librechat-runtime/processes";
import type { VmRuntime } from "@dotfiles/librechat-runtime/qemu";

type WorkspaceStage =
  | "startup"
  | "file-transfer"
  | "workspace-execution"
  | "checkpoint"
  | "resume"
  | "resumed-execution"
  | "cleanup";

interface WorkspaceResponseFailure {
  status: number;
  statusText: string;
  body: string;
}

export class WorkspaceExecutionResponseError extends Error {
  readonly stage: WorkspaceStage;
  readonly status: number;

  constructor(stage: WorkspaceStage, response: WorkspaceResponseFailure) {
    super(
      `Workspace ${stage} POST /runner/api/v2/execute failed: HTTP ${response.status} ${response.statusText}: ${response.body}`,
    );
    this.name = "WorkspaceExecutionResponseError";
    this.stage = stage;
    this.status = response.status;
  }
}

export class WorkspaceBackgroundServiceError extends Error {
  constructor(cause: unknown) {
    super("Workspace fixture failed", { cause });
    this.name = "WorkspaceBackgroundServiceError";
  }
}

export class WorkspaceServiceTimeoutError extends Error {
  readonly url: string;

  constructor(url: string) {
    super(`Timed out waiting for ${url}`);
    this.name = "WorkspaceServiceTimeoutError";
    this.url = url;
  }
}

interface CookieScan {
  sensitive: boolean;
  started: boolean;
}

class CookieArrayRecords {
  private depth = 0;
  private quote: string | undefined;
  private escaped = false;
  private tail = "";

  scan(text: string): CookieScan {
    const source = this.depth === 0 ? this.tail + text : text;
    this.tail = "";
    const result = { sensitive: this.depth > 0, started: false };
    let offset = 0;
    while (offset < source.length) {
      if (this.depth === 0) {
        const rest = source.slice(offset);
        const start = /\b(?:set-cookie|cookie)["']?\s*[:=]\s*\[/iu.exec(rest);
        if (start === null) {
          this.tail = rest.replaceAll(/\s+/gu, " ").slice(-64);
          break;
        }
        offset += start.index + start[0].length;
        this.depth = 1;
        result.sensitive = true;
        result.started = true;
        continue;
      }
      const character = source[offset];
      offset += 1;
      if (this.escaped) {
        this.escaped = false;
        continue;
      }
      if (this.quote !== undefined) {
        if (character === "\\") {
          this.escaped = true;
        } else if (character === this.quote) {
          this.quote = undefined;
        }
        continue;
      }
      if (character === '"' || character === "'") {
        this.quote = character;
      } else if (character === "[") {
        this.depth += 1;
      } else if (character === "]") {
        this.depth -= 1;
      }
    }
    return result;
  }
}

class DiagnosticOutput {
  private records = "";
  private pending = "";
  private oversized = false;
  private pem = false;
  private markerTail = "";
  private begin = false;
  private sensitive = false;
  private readonly cookieArrays = new CookieArrayRecords();
  private cookieSensitive = false;
  private cookieStarted = false;

  private append(record: string): void {
    this.records = (this.records + record).slice(-8192);
  }

  capture(text: string, secrets: readonly string[]): void {
    const parts = text.split("\n");
    for (const [index, part] of parts.entries()) {
      const cookie = this.cookieArrays.scan(
        part + (index === parts.length - 1 ? "" : "\n"),
      );
      this.cookieSensitive ||= cookie.sensitive;
      this.cookieStarted ||= cookie.started;
      const scanned = this.markerTail + part;
      this.sensitive ||= this.pem;
      for (const marker of scanned.matchAll(/-----BEGIN|-----END/gu)) {
        if (marker.index + marker[0].length <= this.markerTail.length) {
          continue;
        }
        this.sensitive = true;
        this.pem = marker[0] === "-----BEGIN";
        this.begin ||= this.pem;
      }
      this.markerTail = scanned.slice(-9);
      if (this.pending.length + part.length > 8192) {
        this.oversized = true;
      }
      this.pending = (this.pending + part).slice(0, 8192);
      if (index === parts.length - 1) {
        continue;
      }
      if (this.begin) {
        this.append("[redacted PEM record]\n");
      }
      if (this.cookieStarted) {
        this.append("[redacted cookie array]\n");
      }
      if (!this.sensitive && !this.cookieSensitive) {
        this.append(
          this.oversized
            ? "[diagnostic record omitted]\n"
            : redactDiagnostic(this.pending + "\n", secrets),
        );
      }
      this.pending = "";
      this.oversized = false;
      this.markerTail = "";
      this.begin = false;
      this.sensitive = false;
      this.cookieSensitive = false;
      this.cookieStarted = false;
    }
  }

  omitPending(): void {
    if (this.pending.length > 0) {
      this.oversized = true;
    }
  }

  report(secrets: readonly string[]): string {
    const pending =
      this.pem || this.sensitive || this.cookieSensitive
        ? ""
        : this.oversized
          ? "[diagnostic record omitted]"
          : redactDiagnostic(this.pending, secrets);
    return redactDiagnostic(this.records + pending, secrets).slice(-8192);
  }
}

export class WorkspaceDiagnostics {
  stage: WorkspaceStage = "startup";
  private readonly accelerator: VmRuntime["accelerator"];
  private readonly secrets: string[] = [];
  private readonly output = new Map<string, DiagnosticOutput>();

  constructor(accelerator: VmRuntime["accelerator"]) {
    this.accelerator = accelerator;
  }

  addSecret(secret: string): void {
    if (secret.length > 0) {
      this.secrets.push(secret);
    }
  }

  capture(output: ProcessOutput): void {
    const key = `${basename(output.executable)}:${output.stream}`;
    if (!this.output.has(key) && this.output.size >= 16) {
      return;
    }
    let records = this.output.get(key);
    if (records === undefined) {
      records = new DiagnosticOutput();
      this.output.set(key, records);
    }
    records.capture(output.text, this.secrets);
  }

  async backendResponse(
    response: Response,
    request: Request,
  ): Promise<Response> {
    if (response.ok) {
      return response;
    }
    const capture = (text: string): void =>
      this.capture({ executable: "backend", stream: "stderr", text });
    capture(
      `${request.method} ${new URL(request.url).pathname}: HTTP ${response.status}\n`,
    );
    const body: ReadableStream<Uint8Array> | null = response.body;
    if (body !== null) {
      const decoder = new TextDecoder();
      let remaining = 16384;
      for await (const chunk of body) {
        const bytes = chunk.subarray(0, remaining);
        capture(decoder.decode(bytes, { stream: true }));
        remaining -= bytes.byteLength;
        if (remaining === 0) {
          this.output.get("backend:stderr")?.omitPending();
          break;
        }
      }
      capture(decoder.decode());
    }
    capture("\n");
    return new Response(null, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    });
  }

  async response(response: Response): Promise<string> {
    const body = await response.text();
    if (!response.ok) {
      throw new WorkspaceExecutionResponseError(this.stage, {
        status: response.status,
        statusText: response.statusText,
        body: redactDiagnostic(body, this.secrets).slice(0, 2048),
      });
    }
    return body;
  }

  finish(
    failure: { error: unknown } | undefined,
    background: unknown,
    cleanup: readonly unknown[],
  ): string | undefined {
    if (failure === undefined && cleanup.length === 0) {
      return undefined;
    }
    return this.report(
      failure === undefined ? cleanup[0] : failure.error,
      background,
      cleanup,
      failure === undefined ? "cleanup" : this.stage,
    );
  }

  report(
    error: unknown,
    background: unknown,
    cleanup: readonly unknown[],
    stage: WorkspaceStage = this.stage,
  ): string {
    return JSON.stringify({
      event: "librechat-workspace-failure",
      stage,
      accelerator: this.accelerator,
      error: errorDiagnostic(error, this.secrets),
      ...(background === undefined
        ? {}
        : { background: errorDiagnostic(background, this.secrets) }),
      cleanup: cleanup.map((cause) => errorDiagnostic(cause, this.secrets)),
      output: Object.fromEntries(
        [...this.output].map(([key, text]) => [key, text.report(this.secrets)]),
      ),
    });
  }
}
