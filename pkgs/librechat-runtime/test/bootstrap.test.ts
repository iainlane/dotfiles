import { expect, it } from "vitest";
import {
  BootstrapAgentOwnerError,
  BootstrapAgentAlreadyExistsError,
  provisionAgents,
  personalAgentData,
  configuredPersonalAgents,
  personalAgentId,
  type BootstrapOwner,
  type PersonalAgent,
  type StoredAgent,
} from "../src/bootstrap.ts";

const owner: BootstrapOwner = {
  userId: "0123456789abcdef01234567",
  email: "owner@example.com",
};

const definition: PersonalAgent = {
  id: "agent_personal",
  name: "Personal",
  provider: "openAI",
  model: "configured-model",
};

it("uses the canonical Ollama endpoint and preserves the deployment agent ID", () => {
  expect(
    configuredPersonalAgents(
      { ollamaUrl: "http://127.0.0.1:11434" },
      { anthropic: "", openai: "", openrouter: "", ollama: "qwen3:4b" },
    ),
  ).toStrictEqual([
    {
      id: personalAgentId("Ollama"),
      name: "Personal (Ollama)",
      provider: "ollama",
      model: "qwen3:4b",
    },
  ]);
});

it.each(["Ollama", "ollama", "customized-provider"])(
  "repairs only the legacy Ollama provider: %s",
  async (provider) => {
    const agent = { ...definition, provider: "ollama" };
    const stored = {
      ...agent,
      provider,
      databaseId: "database-id",
      author: owner.userId,
    };
    const updates: { id: string; provider: string }[] = [];

    await provisionAgents(owner, [agent], {
      load: async () => stored,
      create: async () => stored,
      setProvider: async (existing, canonical) => {
        updates.push({ id: existing.databaseId, provider: canonical });
      },
      grantOwner: async () => {},
    });

    expect(updates).toStrictEqual(
      provider === "Ollama" ? [{ id: "database-id", provider: "ollama" }] : [],
    );
  },
);

it.each([false, true])(
  "configures new agent tools for retrieval %j",
  (fileSearch) => {
    expect(
      personalAgentData(definition, owner, {
        instructions: "Personal instructions",
        servers: ["git"],
        fileSearch,
      }),
    ).toStrictEqual({
      ...definition,
      author: owner.userId,
      instructions: "Personal instructions",
      tools: [
        "execute_code",
        ...(fileSearch ? ["file_search"] : []),
        "sys__all__sys_mcp_git",
      ],
      mcpServerNames: ["git"],
      stateful_code_sessions: true,
      stateful_code_environment: "conversation",
      code_environment_id: "conversation-vm",
      skills_enabled: true,
      skills_scope: "all",
    });
  },
);

it("preserves an existing agent and repairs its owner grant", async () => {
  const events: string[] = [];

  const stored: StoredAgent = {
    id: definition.id,
    databaseId: "database-id",
    author: owner.userId,
    provider: definition.provider,
  };

  await provisionAgents(owner, [definition], {
    load: async () => stored,
    create: async () => {
      events.push("create");

      return stored;
    },
    setProvider: async () => {},
    grantOwner: async (agent) => {
      events.push(`grant:${agent.databaseId}`);
    },
  });

  expect(events).toStrictEqual(["grant:database-id"]);
});

it("refuses to adopt another account's agent", async () => {
  const events: string[] = [];

  const stored: StoredAgent = {
    id: definition.id,
    databaseId: "database-id",
    author: "different-owner",
    provider: definition.provider,
  };

  await expect(
    provisionAgents(owner, [definition], {
      load: async () => stored,
      create: async () => stored,
      setProvider: async () => {},
      grantOwner: async () => {
        events.push("grant");
      },
    }),
  ).rejects.toThrow(BootstrapAgentOwnerError);

  expect(events).toStrictEqual([]);
});

it("recovers a concurrent agent creation without overwriting the existing record", async () => {
  const events: string[] = [];

  const stored: StoredAgent = {
    id: definition.id,
    databaseId: "database-id",
    author: owner.userId,
    provider: definition.provider,
  };

  let firstLookup = true;

  await provisionAgents(owner, [definition], {
    load: async () => {
      if (firstLookup) {
        firstLookup = false;

        return null;
      }

      return stored;
    },
    create: async () => {
      throw new BootstrapAgentAlreadyExistsError();
    },
    setProvider: async () => {},
    grantOwner: async (agent) => {
      events.push(`grant:${agent.databaseId}`);
    },
  });

  expect(events).toStrictEqual(["grant:database-id"]);
});
