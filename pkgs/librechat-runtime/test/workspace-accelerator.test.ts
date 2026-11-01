import { expect, it } from "vitest";
import { workspaceAccelerator } from "./fixtures/accelerator.ts";

it.each([
  { configured: "hvf", support: "1\n", accelerator: "hvf", probed: true },
  { configured: "hvf", support: "0\n", accelerator: "tcg", probed: true },
  { configured: "hvf", support: undefined, accelerator: "tcg", probed: true },
  { configured: "kvm", support: undefined, accelerator: "kvm", probed: false },
  { configured: "tcg", support: undefined, accelerator: "tcg", probed: false },
] as const)(
  "selects $accelerator for $configured with hypervisor support $support",
  ({ configured, support, accelerator, probed }) => {
    let queried = false;
    const selected = workspaceAccelerator(configured, () => {
      queried = true;
      if (support === undefined) {
        throw new Error("The hypervisor probe is unavailable");
      }
      return support;
    });

    expect({ accelerator: selected, probed: queried }).toStrictEqual({
      accelerator,
      probed,
    });
  },
);
