import { defineConfig } from "vitest/config";

export default defineConfig({
  root: import.meta.dirname,
  test: {
    include: ["test/*.test.ts"],
    setupFiles: ["./test/error-equality.ts"],
    testTimeout: 30000,
  },
});
