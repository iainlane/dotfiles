{lib, ...}: let
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
  options = {
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
in {
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;

    # Use ripgrep for file search
    defaultCommand = rgSearch;
    # and ctrl-t (file selection)
    fileWidgetCommand = rgSearch;

    # Use fd for ALT-C (directory selection)
    changeDirWidgetCommand = "fd --type d --hidden --follow --exclude .git";

    defaultOptions = lib.attrValues options ++ bindOptions ++ [helpBinding];
  };
}
