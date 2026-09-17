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

          prose-lint-commit-msg = {
            enable = true;
            name = "prose-lint commit message";
            entry = "${lib.getExe pkgs.prose-lint} commit-msg";
            language = "system";
            stages = ["commit-msg"];
          };

          prose-lint = {
            enable = true;
            name = "prose-lint";
            entry = "${lib.getExe pkgs.prose-lint} check";
            language = "system";
            types = ["text"];
            # Every fixture under this path is an example for a rule to
            # report, so linting the fixtures would always fail.
            excludes = ["^pkgs/prose-lint/fixtures/"];
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

    # Git resolves relative hooks paths against each worktree, where .git may
    # be a file. Use the absolute shared hooks path so linked worktrees run hooks.
    devShells.default = config.pre-commit.devShell.overrideAttrs (previous: {
      shellHook =
        previous.shellHook
        + ''
          ${lib.getExe pkgs.git} config --local core.hooksPath \
            "$(${lib.getExe pkgs.git} rev-parse --path-format=absolute --git-common-dir)/hooks"
        '';
    });
  };
}
