import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        resolve: {
          tsconfigPaths: true,
          alias: {
            "#runtime": fileURLToPath(
              new URL("./packages/runtime/src", import.meta.url),
            ),
          },
        },
        test: { name: "runtime", root: "./packages/runtime" },
      },
      {
        resolve: {
          tsconfigPaths: true,
          alias: {
            "#cli": fileURLToPath(
              new URL("./packages/cli/src", import.meta.url),
            ),
          },
        },
        test: { name: "cli", root: "./packages/cli" },
      },
    ],
  },
});
