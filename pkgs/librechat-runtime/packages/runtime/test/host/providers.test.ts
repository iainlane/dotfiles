import { expect, it } from "vitest";
import {
  CredentialReadError,
  OllamaEndpointError,
} from "#runtime/platform/errors";
import {
  configureProviders,
  hasEmbeddingProvider,
  type CredentialReader,
  type ProviderOptions,
} from "#runtime/host/config";

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

class MissingCredentialFileError extends Error {
  constructor(file: string) {
    super(`No credential file at ${file}`);

    this.name = "MissingCredentialFileError";
  }
}

function credentialFiles(files: Record<string, string>): CredentialReader {
  return async (file, label) => {
    const value = files[file];

    if (value === undefined) {
      throw new CredentialReadError(
        { file, label },
        new MissingCredentialFileError(file),
      );
    }

    return value;
  };
}

it("uses the injected credential source without filesystem access", async () => {
  expect(
    await configureProviders(
      { openaiKeyFile: "/private/openai" },
      credentialFiles({ "/private/openai": "injected-key" }),
    ),
  ).toStrictEqual({
    endpoints: { custom: [] },
    environment: {
      ENDPOINTS: "agents,openAI",
      OPENAI_API_KEY: "injected-key",
    },
  });
});

it("identifies the provider whose credential cannot be read", async () => {
  await expect(
    configureProviders(
      { openaiKeyFile: "/private/openai" },
      credentialFiles({}),
    ),
  ).rejects.toStrictEqual(
    new CredentialReadError(
      { file: "/private/openai", label: "OpenAI" },
      new MissingCredentialFileError("/private/openai"),
    ),
  );
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
    ).rejects.toStrictEqual(new OllamaEndpointError());
  },
);
