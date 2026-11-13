import { defineConfig } from "vitest/config";

export default defineConfig({
  root: import.meta.dirname,
  cacheDir: "./node_modules/.vite",
  test: {
    include: ["*.test.ts", "tests/*.test.ts"],
    provide: {
      launchers: {
        claude: process.env.TEAMCLAUDE_TEST_CLAUDE ?? "",
        server: process.env.TEAMCLAUDE_TEST_SERVER ?? "",
        frontend: process.env.TEAMCLAUDE_TEST_FRONTEND ?? "",
      },
    },
    testTimeout: 30000,
    fsModuleCachePath: "./node_modules/.vitest-cache",
  },
});
