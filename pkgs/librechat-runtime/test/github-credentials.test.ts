import { StatusCodes } from "http-status-codes";
import { expect, it } from "vitest";
import {
  GithubCredentialTransform,
  transformRequestSchema,
} from "../src/github-credentials.ts";

const placeholder = "iron-github-placeholder";

const source = {
  request: {
    method: "GET",
    host: "api.github.com",
    url: "https://api.github.com/user",
    headers: {
      Authorization: { values: [`Bearer ${placeholder}`] },
      Accept: { values: ["application/json"] },
    },
  },
  context: { sni: "api.github.com" },
};

it("injects credentials only after the origin check and preserves other headers", async () => {
  const transform = new GithubCredentialTransform(async () => "host-secret");

  expect(
    await transform.request(transformRequestSchema.parse(source)),
  ).toStrictEqual({
    action: 1,
    modifiedRequest: {
      headers: {
        Authorization: { values: ["Bearer host-secret"] },
        Accept: { values: ["application/json"] },
      },
    },
  });
});

it.each([
  { request: { ...source.request, url: "http://api.github.com/user" } },
  {
    request: {
      ...source.request,
      host: "api.github.com:8443",
      url: "https://api.github.com:8443/user",
    },
  },
  { request: { ...source.request, method: "TRACE" } },
  {
    request: {
      ...source.request,
      host: "evil.example",
      url: "https://evil.example/user",
    },
  },
  {
    request: {
      ...source.request,
      headers: {
        ...source.request.headers,
        authorization: { values: [`Bearer ${placeholder}`] },
      },
    },
  },
  { context: { sni: "" } },
])(
  "denies unsafe credential destinations without reading the host token: %j",
  async (override) => {
    let reads = 0;

    const transform = new GithubCredentialTransform(async () => {
      reads += 1;

      return "host-secret";
    });

    expect({
      result: await transform.request(
        transformRequestSchema.parse({ ...source, ...override }),
      ),
      reads,
    }).toStrictEqual({
      result: {
        action: 2,
        response: {
          statusCode: StatusCodes.FORBIDDEN,
          body: Buffer.from("GitHub credential request denied"),
        },
      },
      reads: 0,
    });
  },
);

it("replaces the exact Git credential placeholder", async () => {
  const transform = new GithubCredentialTransform(async () => "host-secret");

  const input = {
    request: {
      method: "POST",
      host: "github.com",
      url: "https://github.com/user/repo.git/git-receive-pack",
      headers: {
        Authorization: {
          values: [
            `Basic ${Buffer.from(`x-access-token:${placeholder}`).toString("base64")}`,
          ],
        },
      },
    },
    context: { sni: "github.com" },
  };

  expect(await transform.request(input)).toStrictEqual({
    action: 1,
    modifiedRequest: {
      headers: {
        Authorization: {
          values: [
            `Basic ${Buffer.from("x-access-token:host-secret").toString("base64")}`,
          ],
        },
      },
    },
  });
});
