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

export default defineConfig({
  cacheDir: "./node_modules/.vite",
  resolve: { alias: aliases },
  test: { include: ["test/**/*.test.ts"] },
});
