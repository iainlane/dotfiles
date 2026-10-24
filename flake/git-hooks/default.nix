{
  imports = [./configuration.nix];

  perSystem = {
    config,
    pkgs,
    ...
  }: let
    inherit (pkgs) lib;
  in {
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
