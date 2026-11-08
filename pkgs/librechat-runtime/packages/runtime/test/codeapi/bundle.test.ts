import { generateKeyPairSync } from "node:crypto";
import { expect, it } from "vitest";
import {
  BridgeWorker,
  executionManifestBodySha256,
  verifyExecutionManifestWithPublicKey,
} from "@dotfiles/librechat-code-bridge";

it("loads the generated bridge and its native exports", () => {
  const worker = new BridgeWorker({
    codeApiUrl: "http://127.0.0.1:1",
    workerId: "fixture",
    token: "fixture-token",
    runtimeSupervisor: {
      acquire: async () => ({
        execute: async () => ({ status: 200, body: "" }),
      }),
      reset: async () => {},
      quarantine: async () => {},
    },
    capabilities: {
      statefulWorkspace: true,
      sandboxProfile: "nsjail",
      runtimes: ["bash"],
    },
  });
  const keys = generateKeyPairSync("ed25519");

  expect(worker).toBeInstanceOf(BridgeWorker);
  expect(executionManifestBodySha256({ code: "test" })).toBe(
    "0xOGLWp1_c5tBPCedEejwv78lco4iNtruaFxMv-tYMQ",
  );
  expect(() =>
    verifyExecutionManifestWithPublicKey(
      "invalid",
      keys.publicKey.export({ type: "spki", format: "pem" }).toString(),
    ),
  ).toThrow(/manifest/iu);
});
