import type { VmBootSpecification } from "@dotfiles/librechat-runtime/qemu";

export function workspaceAccelerator(
  accelerator: "auto" | VmBootSpecification["accelerator"],
  probe: () => string,
): VmBootSpecification["accelerator"] {
  if (accelerator !== "auto") {
    return accelerator;
  }

  try {
    return probe().trim() === "1" ? "hvf" : "tcg";
  } catch {
    return "tcg";
  }
}
