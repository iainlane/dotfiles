import { expect, it } from "vitest";
import { FetchTransport } from "#frontend/transport";
import { UpstreamError } from "#frontend/errors";

/** Redirects every request and echoes what it received in the body. */
const redirectingEcho: typeof globalThis.fetch = async (input, init) => {
  const request = new Request(input, init);
  return Response.json(
    { url: request.url, method: request.method, redirect: request.redirect },
    { status: 302, headers: { location: "https://elsewhere.invalid/" } },
  );
};

it("uses the injected HTTP client without following upstream redirects", async () => {
  const response = await new FetchTransport(redirectingEcho).send(
    new Request("http://127.0.0.1:3456/v1/messages", { method: "POST" }),
  );
  const received: unknown = await response.json();
  expect({
    status: response.status,
    location: response.headers.get("location"),
    received,
  }).toStrictEqual({
    status: 302,
    location: "https://elsewhere.invalid/",
    received: {
      url: "http://127.0.0.1:3456/v1/messages",
      method: "POST",
      redirect: "manual",
    },
  });
});

it("preserves a failed HTTP client's cause in the typed upstream error", async () => {
  const cause = new TypeError("fetch failed");
  const http: typeof globalThis.fetch = () => Promise.reject(cause);
  await expect(
    new FetchTransport(http).send(
      new Request("http://127.0.0.1:3456/v1/messages"),
    ),
  ).rejects.toStrictEqual(new UpstreamError({ cause }));
});
