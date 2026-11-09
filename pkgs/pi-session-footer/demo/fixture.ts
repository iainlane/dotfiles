export type DemoFile =
  | { kind: "modified"; path: string; before: string; after: string }
  | { kind: "staged" | "untracked"; path: string; content: string };

export interface DemoFixture {
  prompt: string;
  model: {
    provider: string;
    id: string;
    name: string;
    reasoning: boolean;
    contextWindow: number;
    maxTokens: number;
    cost: {
      input: number;
      output: number;
      cacheRead: number;
      cacheWrite: number;
    };
  };
  response: readonly { atMs: number; text: string }[];
  usage: { promptTokens: number; cachedTokens: number; outputTokens: number };
  git: { branch: string; files: readonly DemoFile[] };
}

export const demoFixture: DemoFixture = {
  prompt: "Show the scripted summary.",
  model: {
    provider: "footer-demo",
    id: "scripted-demo",
    name: "Scripted demo (synthetic usage)",
    reasoning: true,
    contextWindow: 131072,
    maxTokens: 4096,
    cost: { input: 2, output: 8, cacheRead: 0.5, cacheWrite: 0 },
  },
  response: [
    { atMs: 400, text: "Scripted local summary. " },
    { atMs: 800, text: "No public service was contacted." },
  ],
  usage: { promptTokens: 16384, cachedTokens: 4096, outputTokens: 240 },
  git: {
    branch: "footer-demo",
    files: [
      {
        kind: "modified",
        path: "service.ts",
        before: "export const state = 'initial';\n",
        after: "export const state = 'modified';\n",
      },
      {
        kind: "staged",
        path: "staged.md",
        content: "Synthetic staged document.\n",
      },
      {
        kind: "untracked",
        path: "notes.md",
        content: "Synthetic untracked document.\n",
      },
    ],
  },
};
