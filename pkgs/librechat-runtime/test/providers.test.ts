import { expect, it } from "vitest";
import { OllamaEndpointError } from "../src/errors.ts";
import {
  configureProviders,
  hasEmbeddingProvider,
  type CredentialReader,
  type ProviderOptions,
} from "../src/config.ts";

it.each<[ProviderOptions, boolean]>([
  [{}, false],
  [{ ollamaUrl: "http://localhost:11434" }, true],
  [{ openaiKeyFile: "/private/openai" }, true],
  [
    {
      anthropicKeyFile: "/private/anthropic",
      openrouterKeyFile: "/private/openrouter",
    },
    false,
  ],
])(
  "enables retrieval only with an embedding provider: %j",
  (options, expected) => {
    expect(hasEmbeddingProvider(options)).toBe(expected);
  },
);

const forbiddenReader: CredentialReader = async () => {
  throw new UnexpectedCredentialAccessError();
};

it("does not read credentials for disabled providers", async () => {
  expect(await configureProviders({}, forbiddenReader)).toStrictEqual({
    endpoints: { custom: [] },
    environment: { ENDPOINTS: "agents" },
  });
});

it("uses the injected credential source without filesystem access", async () => {
  const requests: string[] = [];

  const readKey: CredentialReader = async (file, label) => {
    requests.push(`${label}:${file}`);

    return "injected-key";
  };

  const result = await configureProviders(
    { openaiKeyFile: "/private/openai" },
    readKey,
  );

  expect({ requests, result }).toStrictEqual({
    requests: ["OpenAI:/private/openai"],
    result: {
      endpoints: { custom: [] },
      environment: {
        ENDPOINTS: "agents,openAI",
        OPENAI_API_KEY: "injected-key",
      },
    },
  });
});

class UnexpectedCredentialAccessError extends Error {
  constructor() {
    super("Unexpected credential access");

    this.name = "UnexpectedCredentialAccessError";
  }
}

it.each([
  "invalid",
  "ftp://localhost",
  "http://user:password@localhost",
  "http://localhost?key=secret",
])(
  "rejects an invalid Ollama endpoint with a typed error: %s",
  async (ollamaUrl) => {
    await expect(
      configureProviders({ ollamaUrl }, forbiddenReader),
    ).rejects.toThrow(OllamaEndpointError);
  },
);
