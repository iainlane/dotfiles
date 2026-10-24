import { defineConfig } from "vitest/config";

export default defineConfig({
  root: import.meta.dirname,
  cacheDir: "./node_modules/.vite",
  test: {
    include: ["*.test.ts"],
    testTimeout: 30000,
    fsModuleCachePath: "./node_modules/.vitest-cache",
  },
});
