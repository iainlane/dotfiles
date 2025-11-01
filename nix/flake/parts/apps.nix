{inputs, ...}: {
  # Re-export tools from flake inputs so the justfile can reference pinned
  # versions via `nix run .#<app>`.
  perSystem = {
    lib,
    system,
    ...
  }: {
    apps =
      {
        deploy-rs = {
          type = "app";
          program = lib.getExe inputs.deploy-rs.packages.${system}.deploy-rs;
          meta.description = "Multi-profile Nix deployment tool";
        };
      }
      // lib.optionalAttrs (inputs.system-manager.packages ? ${system}) {
        system-manager = {
          type = "app";
          program = lib.getExe' inputs.system-manager.packages.${system}.default "system-manager";
          meta.description = "Non-NixOS system configuration manager";
        };
      };
  };
}
