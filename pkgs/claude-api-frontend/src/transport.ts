import { UpstreamError } from "./errors.ts";

export interface Transport {
  send(request: Request): Promise<Response>;
}

export class FetchTransport implements Transport {
  private readonly http: typeof globalThis.fetch;

  constructor(http: typeof globalThis.fetch = globalThis.fetch) {
    this.http = http;
  }

  async send(request: Request): Promise<Response> {
    try {
      return await this.http(request, { redirect: "manual" });
    } catch (cause) {
      throw new UpstreamError({ cause });
    }
  }
}
