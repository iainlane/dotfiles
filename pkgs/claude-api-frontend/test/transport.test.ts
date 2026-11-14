import { expect, it } from "vitest";
import { FetchTransport } from "#frontend/transport";
import { UpstreamError } from "#frontend/errors";

it("uses the injected HTTP client without following upstream redirects", async () => {
  const requests: {
    url: string;
    method: string;
    redirect: Request["redirect"];
  }[] = [];
  const http: typeof globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    requests.push({
      url: request.url,
      method: request.method,
      redirect: request.redirect,
    });
    return new Response("upstream", {
      status: 302,
      headers: { location: "https://elsewhere.invalid/" },
    });
  };
  const response = await new FetchTransport(http).send(
    new Request("http://127.0.0.1:3456/v1/messages", { method: "POST" }),
  );
  expect({
    requests,
    status: response.status,
    location: response.headers.get("location"),
    body: await response.text(),
  }).toStrictEqual({
    requests: [
      {
        url: "http://127.0.0.1:3456/v1/messages",
        method: "POST",
        redirect: "manual",
      },
    ],
    status: 302,
    location: "https://elsewhere.invalid/",
    body: "upstream",
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
