import { createHash } from "node:crypto";
import { CODE_ENVIRONMENT_ID } from "./identity.ts";
import type { ProviderOptions } from "./config.ts";

export interface AgentModels {
  anthropic: string;
  openai: string;
  openrouter: string;
  ollama: string;
}

export interface PersonalAgent {
  id: string;
  name: string;
  provider: string;
  model: string;
}

interface PersonalAgentData extends PersonalAgent {
  author: string;
  instructions: string;
  tools: string[];
  mcpServerNames: string[];
  stateful_code_sessions: true;
  stateful_code_environment: "conversation";
  code_environment_id: string;
  skills_enabled: true;
  skills_scope: "all";
}

export interface StoredAgent {
  id: string;
  databaseId: string;
  author: string;
  tenantId?: string;
}

export interface BootstrapOwner {
  userId: string;
  email: string;
  tenantId?: string;
}

export interface PersonalAgentConfiguration {
  instructions: string;
  servers: string[];
  fileSearch: boolean;
}

export interface AgentBootstrapStore {
  load(id: string): Promise<StoredAgent | null>;

  create(agent: PersonalAgent, owner: BootstrapOwner): Promise<StoredAgent>;

  grantOwner(agent: StoredAgent, owner: BootstrapOwner): Promise<void>;
}

export class BootstrapAgentAlreadyExistsError extends Error {
  constructor() {
    super("The deployment agent was created by another bootstrap process");

    this.name = "BootstrapAgentAlreadyExistsError";
  }
}

export class BootstrapAgentCreationLostError extends Error {
  constructor() {
    super(
      "The concurrent deployment agent creation did not produce a readable record",
    );

    this.name = "BootstrapAgentCreationLostError";
  }
}

export class BootstrapAgentOwnerError extends Error {
  constructor() {
    super(
      "The deployment agent ID is already registered to another account or tenant",
    );

    this.name = "BootstrapAgentOwnerError";
  }
}

export function personalAgentId(provider: string): string {
  return `agent_${createHash("sha256").update(`dotfiles-librechat:${provider}`).digest("hex").slice(0, 21)}`;
}

export function configuredPersonalAgents(
  providers: ProviderOptions,
  models: AgentModels,
): PersonalAgent[] {
  const candidates = [
    {
      label: "Anthropic",
      provider: "anthropic",
      model: models.anthropic,
      enabled: typeof providers.anthropicKeyFile === "string",
    },
    {
      label: "OpenAI",
      provider: "openAI",
      model: models.openai,
      enabled: typeof providers.openaiKeyFile === "string",
    },
    {
      label: "OpenRouter",
      provider: "OpenRouter",
      model: models.openrouter,
      enabled: typeof providers.openrouterKeyFile === "string",
    },
    {
      label: "Ollama",
      provider: "Ollama",
      model: models.ollama,
      enabled: typeof providers.ollamaUrl === "string",
    },
  ];

  return candidates
    .filter((candidate) => candidate.enabled)
    .map(({ label, provider, model }) => ({
      id: personalAgentId(provider),
      name: `Personal (${label})`,
      provider,
      model,
    }));
}

export function personalAgentData(
  agent: PersonalAgent,
  owner: BootstrapOwner,
  configuration: PersonalAgentConfiguration,
): PersonalAgentData {
  const { instructions, servers, fileSearch } = configuration;

  return {
    ...agent,
    author: owner.userId,
    instructions,
    tools: [
      "execute_code",
      ...(fileSearch ? ["file_search"] : []),
      ...servers.map((server) => `sys__all__sys_mcp_${server}`),
    ],
    mcpServerNames: servers,
    stateful_code_sessions: true,
    stateful_code_environment: "conversation",
    code_environment_id: CODE_ENVIRONMENT_ID,
    skills_enabled: true,
    skills_scope: "all",
  };
}

export async function provisionAgents(
  owner: BootstrapOwner,
  agents: PersonalAgent[],
  store: AgentBootstrapStore,
): Promise<void> {
  await Promise.all(
    agents.map(async (definition) => {
      const existing = await store.load(definition.id);

      let agent = existing;

      if (agent === null) {
        try {
          agent = await store.create(definition, owner);
        } catch (error) {
          if (!(error instanceof BootstrapAgentAlreadyExistsError)) {
            throw error;
          }

          agent = await store.load(definition.id);
        }
      }

      if (agent === null) {
        throw new BootstrapAgentCreationLostError();
      }

      if (agent.author !== owner.userId || agent.tenantId !== owner.tenantId) {
        throw new BootstrapAgentOwnerError();
      }

      await store.grantOwner(agent, owner);
    }),
  );
}
