{inputs, ...}: {
  imports = [inputs.git-hooks-nix.flakeModule];

  perSystem = {config, ...}: let
    inherit (config._module.args) pkgs;
  in {
    pre-commit.check.enable = false;

    pre-commit.settings.hooks = {
      check-added-large-files.enable = true;
      check-yaml.enable = true;
      end-of-file-fixer.enable = true;
      trim-trailing-whitespace = {
        enable = true;
        excludes = ["doc/rust-target-picker\\.txt"];
      };

      flake-check = let
        nix = pkgs.lib.getExe pkgs.nix;
        script = pkgs.writeShellScript "flake-check" ''
          if [ -f flake.nix ]; then
            ${nix} flake check --all-systems
          else
            ${nix} flake check --all-systems nix/
          fi
        '';
      in {
        enable = true;
        name = "nix flake check";
        entry = toString script;
        language = "system";
        pass_filenames = false;
        files = "\\.(nix)$|^flake\\.lock$";
      };
    };

    devShells.default = pkgs.mkShell {
      inherit (config.pre-commit) shellHook;
      packages = config.pre-commit.settings.enabledPackages;
    };
  };
}
