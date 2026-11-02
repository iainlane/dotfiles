{
  inputs,
  final,
}: {
  pi = import ../../features/ai/pi/pi-package.nix {
    inherit inputs;
    system = final.stdenv.hostPlatform.system;
  };
}
