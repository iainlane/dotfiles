import { z } from "zod";

const port = z.number().int().min(1).max(65535);

const hostPortsSchema = z.object({
  mongodb: port.default(27018),
  postgres: port.default(5434),
  redis: port.default(6384),
  meilisearch: port.default(7701),
  objects: port.default(9004),
  objectsConsole: port.default(9005),
  iron: port.default(3128),
  controller: port.default(3193),
  archive: port.default(3194),
  codeApi: port.default(3112),
  fileServer: z.number().int().min(0).max(65535).default(0),
  toolServer: port.default(3033),
  egressGateway: port.default(3190),
  workerHealth: port.default(3113),
  librechat: port.default(3080),
});

export const hostManifestSchema = z.object({
  stateDirectory: z.string(),
  socketDirectory: z.string().optional(),
  ports: hostPortsSchema.prefault({}),
  sopsProgram: z.string().nullable().default(null),
  homeDirectory: z.string(),
  hookCommand: z.string(),
  skillsDirectory: z.string(),
  instructions: z.string(),
  chatPrompt: z.string().refine((value) => value.trim().length > 0),
  models: z.object({
    anthropic: z.string(),
    openai: z.string(),
    openrouter: z.string(),
    ollama: z.string(),
  }),
  providers: z.object({
    ollamaUrl: z.url().nullable(),
    openaiKeyFile: z.string().nullable(),
    anthropicKeyFile: z.string().nullable(),
    openrouterKeyFile: z.string().nullable(),
  }),
  mcpServers: z.record(z.string(), z.record(z.string(), z.unknown())),
  localMcpServers: z.array(z.string()),
  mcpHeaderFiles: z.record(
    z.string(),
    z.record(
      z.string(),
      z.object({ file: z.string(), prefix: z.string().default("") }),
    ),
  ),
  programs: z.object({
    librechat: z.string(),
    librechatRoot: z.string(),
    node: z.string(),
    mongodb: z.string(),
    redis: z.string(),
    meilisearch: z.string(),
    postgres: z.string(),
    initdb: z.string(),
    psql: z.string(),
    rustfs: z.string(),
    codeApi: z.string(),
    codeWorker: z.string(),
    fileServer: z.string(),
    toolServer: z.string(),
    egressGateway: z.string(),
    rag: z.string(),
    iron: z.string(),
    ironProto: z.string(),
    gh: z.string(),
    agentsview: z.string(),
    qemu: z.string(),
    nixStore: z.string(),
    socat: z.string(),
  }),
  guest: z.object({
    image: z.string(),
    kernel: z.string(),
    initrd: z.string(),
    init: z.string(),
    architecture: z.enum(["aarch64", "x86_64"]),
    accelerator: z.enum(["hvf", "kvm"]),
  }),
});

export type HostManifest = z.infer<typeof hostManifestSchema>;
