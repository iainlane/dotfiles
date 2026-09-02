{inputs, ...}: {
  imports = [inputs.git-hooks-nix.flakeModule];

  perSystem = {config, ...}: let
    inherit (config._module.args) pkgs;

    # renovate: datasource=docker depName=ghcr.io/underwhelmingperformance/wrapscallion versioning=docker
    wrapscallionTag = "v0.2.2@sha256:3cdb422e06ce2926cf2cda1c0507fcdd39eb51f0c45b1ac367ed1813669e8b72";
    wrapscallionImage = "ghcr.io/underwhelmingperformance/wrapscallion:${wrapscallionTag}";
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
            entry = "${wrapscallionImage} --output-format terminal --edit";
            language = "docker_image";
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
