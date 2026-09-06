{
  lib,
  options,
  ...
}: let
  # `description` is the text shown for a key in the header and in the `?`
  # help. `showInHeader = false` keeps a key out of the header but leaves it
  # in the help.
  keybindings = {
    "ctrl-/" = {
      action = "toggle-preview";
      description = "toggle preview";
    };
    "ctrl-u" = {
      action = "preview-page-up";
      description = "preview page up";
    };
    "ctrl-d" = {
      action = "preview-page-down";
      description = "preview page down";
    };
    "ctrl-f" = {
      action = "preview-page-down";
      description = "preview page down";
      showInHeader = false;
    };
    "ctrl-b" = {
      action = "preview-page-up";
      description = "preview page up";
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

  bindOptions = lib.mapAttrsToList (key: value: "--bind=${key}:${value.action}") keybindings;

  # The lines the `?` binding prints in the preview window.
  helpLines =
    ["Keybindings:"]
    ++ (lib.mapAttrsToList (key: value: "  ${key}: ${value.description}") keybindings)
    ++ ["  ?: show this help" "  enter: confirm selection"];

  helpText = lib.concatStringsSep "\n" helpLines;

  headerKeys = lib.concatStringsSep " | " (
    lib.mapAttrsToList (key: value: "${key} ${value.description}") (
      lib.filterAttrs (_k: v: v.showInHeader or true) keybindings
    )
  );

  fzfOptions = {
    # Layout
    height = "--height=40%";
    layout = "--layout=reverse";
    border = "--border=rounded";
    info = "--inline-info";

    previewWindow = "--preview-window=right:50%:wrap";

    header = ''--header=\"[?] for help | ${headerKeys}\"'';

    # Search behaviour
    multi = "--multi";
    cycle = "--cycle";
    keepRight = "--keep-right";
  };

  # The `?` binding's preview command contains spaces and newlines, so the
  # whole binding is quoted here. The plain `key:action` bindings contain
  # neither.
  helpBinding = "--bind=\\\"?:preview:echo '${helpText}'\\\"";

  # ripgrep lists files for the default command and the ctrl-t widget; fd
  # lists directories for the alt-c widget.
  rgSearch = "rg --files --hidden --follow --glob '!.git'";
  fdSearch = "fd --type d --hidden --follow --exclude .git";

  # home-manager 26.11 renamed `programs.fzf.fileWidgetCommand` and
  # `changeDirWidgetCommand` to the nested `fileWidget.command` and
  # `changeDirWidget.command`, keeping the flat names as renamed options. A
  # host on 26.05 has only the flat names; a host on 26.11 accepts them and
  # warns. Set whichever form the running home-manager declares, and delete
  # the flat branch once no host is on 26.05.
  widgetCommands =
    if options.programs.fzf ? fileWidget
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

      defaultCommand = rgSearch;

      defaultOptions = lib.attrValues fzfOptions ++ bindOptions ++ [helpBinding];
    }
    // widgetCommands;
}
