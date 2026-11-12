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
  cacheDir: "./.cache/vitest",
  resolve: { alias: aliases },
  test: {
    fileParallelism: false,
    // A test that never finishes never runs its onTestFinished hooks, which
    // print the terminal screen and close Pi. The limits make a hung test
    // fail and report what it was waiting for.
    testTimeout: 600_000,
    hookTimeout: 600_000,
    projects: [
      {
        extends: true,
        test: {
          name: "unit",
          include: ["test/unit/**/*.test.ts"],
        },
      },
      {
        extends: true,
        test: {
          name: "integration",
          include: ["test/integration/**/*.test.ts"],
        },
      },
    ],
  },
});
