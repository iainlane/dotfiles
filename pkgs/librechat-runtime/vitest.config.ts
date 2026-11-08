import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        resolve: { tsconfigPaths: true },
        test: { name: "runtime", root: "./packages/runtime" },
      },
      {
        resolve: { tsconfigPaths: true },
        test: { name: "cli", root: "./packages/cli" },
      },
    ],
  },
});
