import type { VmBootSpecification } from "../../src/qemu.ts";

export function workspaceAccelerator(
  accelerator: VmBootSpecification["accelerator"],
  probe: () => string,
): VmBootSpecification["accelerator"] {
  if (accelerator !== "hvf") {
    return accelerator;
  }

  try {
    return probe().trim() === "1" ? "hvf" : "tcg";
  } catch {
    return "tcg";
  }
}
