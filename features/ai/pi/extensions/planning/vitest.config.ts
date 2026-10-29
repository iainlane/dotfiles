import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const hostModules = [
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-agent-core",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-ai/compat",
  "@earendil-works/pi-tui",
  "typebox",
  "typebox/value",
  "typebox/compile",
];

const runtimeRoot = process.env.PI_TEST_SUBAGENTS;
const runtimeRequire =
  runtimeRoot !== undefined && runtimeRoot !== ""
    ? createRequire(join(runtimeRoot, "package.json"))
    : undefined;

const integration = [
  "test/store.test.ts",
  "test/native.test.ts",
  "test/rpc.test.ts",
];

export default defineConfig({
  plugins: [
    {
      name: "planning-subagent-runtime",
      enforce: "pre",
      resolveId(source: string) {
        if (runtimeRequire && /^pi-subagents(?:\/|$)/.test(source)) {
          return runtimeRequire.resolve(source);
        }
        return null;
      },
    },
  ],
  resolve: {
    alias: hostModules.map((name) => ({
      find: new RegExp(`^${name.replaceAll("/", "\\/")}$`),
      replacement: fileURLToPath(import.meta.resolve(name)),
    })),
  },
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
