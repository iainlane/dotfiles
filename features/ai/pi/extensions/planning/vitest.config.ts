import { defineConfig } from "vitest/config";

const integration = [
  "test/store.test.ts",
  "test/native.test.ts",
  "test/rpc.test.ts",
];

export default defineConfig({
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
