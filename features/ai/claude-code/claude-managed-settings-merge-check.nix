{modelCatalog}: {
  pkgs,
  inputs,
  ...
}: let
  inherit (pkgs) lib;

  hook = command: {
    hooks = [
      {
        type = "command";
        inherit command;
      }
    ];
  };

  evaluated = lib.evalModules {
    specialArgs = {
      inherit inputs pkgs;
      defaultModels = modelCatalog.defaults;
    };

    modules = [
      ./managed-settings-common.nix
      {
        dotfiles.claudeCode.managedSettings.hooks = {
          SessionStart = [(hook "first")];
          Stop = [(hook "stop")];
        };
      }
      {
        # This list also has the first definition's hook, and its order
        # gives the same result whichever definition is merged first.
        dotfiles.claudeCode.managedSettings.hooks.SessionStart = [
          (hook "first")
          (hook "second")
        ];
      }
    ];
  };

  # The base settings add the prose-lint hooks after every other definition.
  proseLint = import ../prose-lint-hooks.nix {inherit lib pkgs;};

  expected = {
    SessionStart = [(hook "first") (hook "second")];
    Stop = [(hook "stop")] ++ proseLint.Stop;
    inherit (proseLint) PostToolUse PreToolUse;
  };

  actual = evaluated.config.dotfiles.claudeCode.managedSettings.hooks;
in {
  claude-managed-settings-merge = assert lib.assertMsg (actual == expected)
  "Claude Code's managed settings merged the hooks into ${builtins.toJSON actual}, not ${builtins.toJSON expected}";
    pkgs.runCommandLocal "claude-managed-settings-merge" {} ''
      touch $out
    '';
}
