{
  hostConfig,
  systemConfig,
}: {
  inputs,
  pkgs,
  ...
}: {
  "falcon-kernel-${hostConfig.name}" = import ./test.nix {
    inherit inputs pkgs;
    inherit (systemConfig.boot) kernelPackages;
  };
}
