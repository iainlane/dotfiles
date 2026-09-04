{
  lib,
  inputs,
  options,
  ...
}: let
  # Keybindings with descriptions
  keybindings = {
    "ctrl-/" = {
      action = "toggle-preview";
      description = "toggle preview";
    };
    "ctrl-u" = {
      action = "preview-page-up";
      description = "scroll up";
    };
    "ctrl-d" = {
      action = "preview-page-down";
      description = "scroll down";
    };
    "ctrl-f" = {
      action = "preview-page-down";
      description = "page forward";
      showInHeader = false;
    };
    "ctrl-b" = {
      action = "preview-page-up";
      description = "page back";
      showInHeader = false;
    };
    "alt-w" = {
      action = "toggle-preview-wrap";
      description = "toggle wrap";
    };
    "tab" = {
      action = "toggle+down";
      description = "select multiple";
      showInHeader = false;
    };
  };

  # Generate --bind options from keybindings
  bindOptions = lib.mapAttrsToList (key: value: "--bind=${key}:${value.action}") keybindings;

  # Generate help text for the ? keybinding
  helpLines =
    ["Keybindings:"]
    ++ (lib.mapAttrsToList (key: value: "  ${key}: ${value.description}") keybindings)
    ++ ["  ?: show this help" "  enter: confirm selection"];

  helpText = lib.concatStringsSep "\n" helpLines;

  # Generate compact header showing key bindings
  headerKeys = lib.concatStringsSep " | " (
    lib.mapAttrsToList (key: value: "${key} ${value.description}") (
      lib.filterAttrs (_k: v: v.showInHeader or true) keybindings
    )
  );

  # Other options
  fzfOptions = {
    # Layout
    height = "--height=40%";
    layout = "--layout=reverse";
    border = "--border=rounded";
    info = "--inline-info";

    # Preview window
    previewWindow = "--preview-window=right:50%:wrap";

    # Header with common keybindings
    header = ''--header=\"[?] for help | ${headerKeys}\"'';

    # Search behaviour
    multi = "--multi";
    cycle = "--cycle";
    keepRight = "--keep-right";
  };

  # Help keybinding (separate because it needs special handling)
  helpBinding = "--bind=\\\"?:preview:echo '${helpText}'\\\"";

  rgSearch = "rg --files --hidden --follow --glob '!.git'";
  fdSearch = "fd --type d --hidden --follow --exclude .git";

  # home-manager unstable (26.11) renamed `programs.fzf.fileWidgetCommand` and
  # `changeDirWidgetCommand` to the nested `fileWidget.command` and
  # `changeDirWidget.command`. Stable (26.05) only knows the flat names, so we
  # speak whichever form the running home-manager declares.
  usesNestedWidget = options.programs.fzf ? fileWidget;

  # The flat branch below exists only for stable, which is on 26.05. Read the
  # stable input's release directly so that bumping `home-manager-stable` past
  # 26.05 fails the build: at that point stable has the rename too and this whole
  # shim can go. Keying on the stable input makes the failure fire the moment
  # stable is bumped.
  stableRelease = (lib.importJSON (inputs.home-manager-stable + "/release.json")).release;

  widgetCommands = assert lib.assertMsg (stableRelease == "26.05") ''
    modules/cli-tools/fzf.nix carries a compatibility shim for home-manager
    stable 26.05, which still uses the flat `programs.fzf.fileWidgetCommand`.
    The `home-manager-stable` input is now on ${stableRelease}, which has the
    renamed nested `fileWidget.command`. Drop this shim and set the nested
    options directly.
  '';
    if usesNestedWidget
    then {
      fileWidget.command = rgSearch;
      changeDirWidget.command = fdSearch;
    }
    else {
      fileWidgetCommand = rgSearch;
      changeDirWidgetCommand = fdSearch;
    };
in {
  programs.fzf =
    {
      enable = true;
      enableZshIntegration = true;

      # Use ripgrep for file search and ctrl-t; fd for ALT-C
      defaultCommand = rgSearch;

      defaultOptions = lib.attrValues fzfOptions ++ bindOptions ++ [helpBinding];
    }
    // widgetCommands;
}
