import { expect, it } from "vitest";
import {
  BootstrapAgentOwnerError,
  BootstrapAgentAlreadyExistsError,
  provisionAgents,
  personalAgentData,
  configuredPersonalAgents,
  type AgentBootstrapStore,
  type BootstrapOwner,
  type PersonalAgent,
  type StoredAgent,
} from "#runtime/accounts/bootstrap";

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

class AgentDatabase implements AgentBootstrapStore {
  readonly agents = new Map<string, StoredAgent>();
  readonly owners = new Map<string, string[]>();

  /** An agent that another bootstrap process creates between this process's lookup and its insert. */
  concurrentCreation: StoredAgent | undefined;

  constructor(agents: StoredAgent[] = []) {
    for (const agent of agents) {
      this.agents.set(agent.id, structuredClone(agent));
    }
  }

  async load(id: string): Promise<StoredAgent | null> {
    const agent = this.agents.get(id);

    return agent === undefined ? null : structuredClone(agent);
  }

  async create(
    agent: PersonalAgent,
    creator: BootstrapOwner,
  ): Promise<StoredAgent> {
    if (this.concurrentCreation !== undefined) {
      this.agents.set(this.concurrentCreation.id, this.concurrentCreation);
    }

    if (this.agents.has(agent.id)) {
      throw new BootstrapAgentAlreadyExistsError();
    }

    const stored: StoredAgent = {
      id: agent.id,
      databaseId: `database-${agent.id}`,
      author: creator.userId,
      provider: agent.provider,
    };

    this.agents.set(agent.id, stored);

    return structuredClone(stored);
  }

  async grantOwner(agent: StoredAgent, grantee: BootstrapOwner): Promise<void> {
    const owners = this.owners.get(agent.databaseId) ?? [];

    if (!owners.includes(grantee.userId)) {
      this.owners.set(agent.databaseId, [...owners, grantee.userId]);
    }
  }

  async setProvider(agent: StoredAgent, provider: string): Promise<void> {
    const stored = this.agents.get(agent.id);

    if (stored?.provider === agent.provider) {
      stored.provider = provider;
    }
  }

  contents(): {
    agents: StoredAgent[];
    owners: Record<string, string[]>;
  } {
    return {
      agents: [...this.agents.values()],
      owners: Object.fromEntries(this.owners),
    };
  }
}

const existing: StoredAgent = {
  id: definition.id,
  databaseId: "database-id",
  author: owner.userId,
  provider: definition.provider,
};

it("uses the canonical Ollama endpoint and preserves the deployment agent ID", () => {
  expect(
    configuredPersonalAgents(
      { ollamaUrl: "http://127.0.0.1:11434" },
      { anthropic: "", openai: "", openrouter: "", ollama: "qwen3:4b" },
    ),
  ).toStrictEqual([
    {
      id: "agent_4ddc3060371e804f1ec74",
      name: "Personal (Ollama)",
      provider: "ollama",
      model: "qwen3:4b",
    },
  ]);
});

it.each(["Ollama", "ollama", "customized-provider"])(
  "repairs only the legacy Ollama provider: %s",
  async (provider) => {
    const database = new AgentDatabase([{ ...existing, provider }]);

    await provisionAgents(
      owner,
      [{ ...definition, provider: "ollama" }],
      database,
    );

    expect(database.contents()).toStrictEqual({
      agents: [
        { ...existing, provider: provider === "Ollama" ? "ollama" : provider },
      ],
      owners: { "database-id": [owner.userId] },
    });
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
  const database = new AgentDatabase([existing]);

  await provisionAgents(owner, [definition], database);

  expect(database.contents()).toStrictEqual({
    agents: [existing],
    owners: { "database-id": [owner.userId] },
  });
});

it("refuses to adopt another account's agent", async () => {
  const foreign = { ...existing, author: "different-owner" };
  const database = new AgentDatabase([foreign]);

  await expect(
    provisionAgents(owner, [definition], database),
  ).rejects.toStrictEqual(new BootstrapAgentOwnerError());

  expect(database.contents()).toStrictEqual({ agents: [foreign], owners: {} });
});

it("recovers a concurrent agent creation without overwriting the existing record", async () => {
  const database = new AgentDatabase();
  database.concurrentCreation = existing;

  await provisionAgents(owner, [definition], database);

  expect(database.contents()).toStrictEqual({
    agents: [existing],
    owners: { "database-id": [owner.userId] },
  });
});
