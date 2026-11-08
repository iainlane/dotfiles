import type { HostManifest } from "@dotfiles/librechat-runtime/manifest";
import type { NativeHostStack } from "@dotfiles/librechat-runtime/host-stack";

type StackManifest = ConstructorParameters<typeof NativeHostStack>[0];

export const compatible: HostManifest extends StackManifest ? true : never =
  true;
