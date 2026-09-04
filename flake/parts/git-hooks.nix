{inputs, ...}: {
  imports = [inputs.git-hooks-nix.flakeModule];

  perSystem = {config, ...}: let
    inherit (config._module.args) pkgs;
    inherit (pkgs) lib;

    promptConformanceChecks = [
      ".#claude-prompt-conformance.tests.conformance"
      ".#claude-prompt-conformance.tests.codexProtocol"
      ".#claude-prompt-conformance.tests.codexEndpoint"
      ".#claude-prompt-conformance.tests.claudeEndpoint"
    ];
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
            name = "prompt conformance";
            entry = "./scripts/check-prompt-conformance.bash ${builtins.concatStringsSep " " promptConformanceChecks}";
            language = "system";
            pass_filenames = false;
            always_run = true;
            after = ["flake-check"];
          };
        };
      };
    };

    devShells.default = pkgs.mkShell {
      inherit (config.pre-commit) shellHook;
      packages = config.pre-commit.settings.enabledPackages;
    };
  };
}
