{inputs, ...}: {
  imports = [inputs.git-hooks-nix.flakeModule];

  perSystem = {
    config,
    pkgs,
    ...
  }: let
    inherit (pkgs) lib;
  in {
    pre-commit = {
      check.enable = false;

      settings = {
        hooks = {
          check-added-large-files.enable = true;
          check-yaml.enable = true;
          end-of-file-fixer.enable = true;
          trim-trailing-whitespace = {
            enable = true;
            # A blank context line in a unified diff is a single space, which
            # this hook would strip.
            excludes = ["\\.patch$"];
          };

          wrapscallion = {
            enable = true;
            description = "Lint Conventional Commit messages and 72-column bodies.";
            entry = "${lib.getExe pkgs.wrapscallion} --output-format terminal --edit";
            language = "system";
            stages = ["commit-msg"];
          };

          nix-format = {
            enable = true;
            name = "nix fmt";
            entry = "nix fmt";
            language = "system";
            require_serial = true;
            before = ["flake-check"];
          };

          flake-check = {
            enable = true;
            name = "nix flake check";
            entry = "nix flake check --all-systems";
            language = "system";
            pass_filenames = false;
          };

          prompt-conformance = {
            enable = true;
            name = "prompt conformance Python checks";
            entry = "./scripts/check-prompt-conformance.bash .#claude-prompt-conformance.tests.python";
            language = "system";
            pass_filenames = false;
            always_run = true;
            after = ["flake-check"];
          };
        };
      };
    };

    devShells.default = config.pre-commit.devShell;
  };
}
