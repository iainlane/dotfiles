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
      trim-trailing-whitespace.enable = true;

      flake-check = {
        enable = true;
        name = "nix flake check";
        entry = "nix flake check --all-systems";
        language = "system";
        pass_filenames = false;
        files = "\\.(nix)$|/flake\\.lock$";
      };
    };

    devShells.default = pkgs.mkShell {
      inherit (config.pre-commit) shellHook;
      packages = config.pre-commit.settings.enabledPackages;
    };
  };
}
