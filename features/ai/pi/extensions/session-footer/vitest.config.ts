import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const aliases = {
  ...Object.fromEntries(
    ["pi-coding-agent", "pi-agent-core", "pi-ai", "pi-tui"].map((name) => [
      `@mariozechner/${name}`,
      fileURLToPath(import.meta.resolve(`@earendil-works/${name}`)),
    ]),
  ),
  "@sinclair/typebox": fileURLToPath(import.meta.resolve("typebox")),
};

const integration = [
  "test/core-*.test.ts",
  "test/btw.test.ts",
  "test/git.test.ts",
  "test/patches.test.ts",
  "test/tui.test.ts",
];

export default defineConfig({
  cacheDir: "./node_modules/.vite",
  resolve: { alias: aliases },
  test: {
    projects: [
      {
        extends: true,
        test: {
          name: "unit",
          include: ["test/**/*.test.ts"],
          exclude: integration,
        },
      },
      { extends: true, test: { name: "integration", include: integration } },
    ],
  },
});
