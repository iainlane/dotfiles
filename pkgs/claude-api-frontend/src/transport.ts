import { UpstreamError } from "./errors.ts";

export interface Transport {
  send(request: Request): Promise<Response>;
}

export class FetchTransport implements Transport {
  async send(request: Request): Promise<Response> {
    try {
      return await fetch(request, { redirect: "manual" });
    } catch (cause) {
      throw new UpstreamError({ cause });
    }
  }
}
