{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (import ../../../lib/discovery.nix {inherit lib;}) fileNames;
  pluginSpecs = import ./plugins.nix;
  zstylesPre = builtins.readFile ./zstyles-before.zsh;
  zstylesPost = builtins.readFile ./zstyles-after.zsh;
  completionCache = "${config.xdg.cacheHome}/zsh/$ZSH_VERSION";

  pluginsDir = ./plugins;
  localPlugins = fileNames pluginsDir ".plugin.zsh";

  # Colourise manpages with `bat`. man renders bold/underline as backspace
  # overstrikes and may emit ANSI colour codes; strip both so `bat` can
  # re-highlight from clean text.
  # https://github.com/sharkdp/bat?tab=readme-ov-file#man
  batManPager = pkgs.writeShellScript "bat-manpager" ''
    ${lib.getExe pkgs.gnused} -u -e 's/\x1B\[[0-9;]*m//g; s/.\x08//g' \
      | ${lib.getExe pkgs.bat} -p -lman
  '';
in {
  home.sessionPath = [
    "${config.home.homeDirectory}/.local/bin"
    "${config.home.homeDirectory}/bin"
  ];

  programs.zsh = {
    antidote = {
      enable = true;
      package = pkgs.antidote;
      plugins = pluginSpecs;
    };

    autosuggestion = {
      enable = true;
      strategy = [
        "history"
        "completion"
      ];
    };

    completionInit = ''
      mkdir -p "${completionCache}"
      autoload -Uz compinit
      compinit -d "${completionCache}/.zcompdump"
    '';

    defaultKeymap = "emacs";

    dotDir = "${config.xdg.configHome}/zsh";

    enable = true;

    enableCompletion = true;
    enableVteIntegration = true;

    envExtra = ''
      setopt CASE_PATHS
      skip_global_compinit=1
      ZLE_RPROMPT_INDENT=0
    '';

    history = {
      expireDuplicatesFirst = true;
      extended = true;
      ignoreAllDups = true;
      ignoreDups = true;
      ignoreSpace = true;
      path = "${config.xdg.dataHome}/zsh/zsh_history";
      save = 100000;
      share = false;
      size = 100000;
    };

    initContent = lib.mkMerge [
      (lib.mkBefore zstylesPre)
      # Home Manager loads antidote at order 550, and cursor.plugin.zsh has to
      # redefine a widget from zephyr's editor plugin after antidote loads it.
      (lib.mkOrder 560 (
        lib.concatMapStringsSep "\n" (name: "source ${pluginsDir}/${name}") localPlugins
      ))
      (lib.mkAfter zstylesPost)
    ];

    sessionVariables = {
      VISUAL = "nvim";
      MANPAGER = "${batManPager}";
    };

    setOptions = [
      # Directory navigation
      ## If command is directory name, cd to it
      "AUTO_CD"
      ## Make cd push old directory onto stack
      "AUTO_PUSHD"
      ## Don't push duplicate directories
      "PUSHD_IGNORE_DUPS"

      # History
      ## Show command with history expansion before running it
      "HIST_VERIFY"
      ## Add commands to history as they are typed
      "INC_APPEND_HISTORY"

      # Completion
      ## Add trailing slash to completed directories
      "AUTO_PARAM_SLASH"
      ## Complete aliases
      "COMPLETE_ALIASES"
      ## Complete from both ends of word
      "COMPLETE_IN_WORD"
      ## Show file types in completion list
      "LIST_TYPES"

      # Globbing
      ## Use extended globbing syntax (#, ~, ^)
      "EXTENDED_GLOB"
      ## Use globbing in completion
      "GLOB_COMPLETE"
      ## Sort numerically when globbing
      "NUMERIC_GLOB_SORT"

      # Input/Output
      ## Try to correct command spelling
      "CORRECT"
      ## Disable flow control (Ctrl+S/Ctrl+Q)
      "NO_FLOW_CONTROL"
      ## Allow comments in interactive shells
      "INTERACTIVE_COMMENTS"
      ## Array expansion in parameters
      "RC_EXPAND_PARAM"

      # Job Control
      ## Check for running jobs before exiting
      "CHECK_JOBS"
      ## Report status of background jobs immediately
      "NOTIFY"

      # Prompting
      ## Allow parameter/command substitution in prompt
      "PROMPT_SUBST"
    ];

    shellAliases = {
      cat = "bat";
      chmod = "chmod -v";
      chown = "chown -v";
      cp = "cp -iv";
      ln = "ln -v";
      mkdir = "mkdir -v";
      mv = "mv -iv";
    };

    syntaxHighlighting.enable = true;
  };

  home.activation.zshCompletionDump = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD ${config.programs.zsh.package}/bin/zsh -c '
      mkdir -p "${completionCache}"
      autoload -Uz compinit
      compinit -u -d "${completionCache}/.zcompdump"
      zcompile "${completionCache}/.zcompdump"
    '
  '';
}
