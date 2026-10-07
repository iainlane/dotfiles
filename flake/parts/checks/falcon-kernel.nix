{
  config,
  inputs,
  lib,
  ...
}: {
  perSystem = {system, ...}: {
    checks = lib.optionalAttrs (system == "x86_64-linux") {
      falcon-kernel-bonington = let
        host = config.flake.nixosConfigurations.bonington;
      in
        import ../../../features/work/falcon/test.nix {
          inherit inputs;
          inherit (host) pkgs;
          inherit (host.config.boot) kernelPackages;
        };
    };
  };
}
