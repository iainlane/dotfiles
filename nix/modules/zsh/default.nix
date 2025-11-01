{
  config,
  pkgs,
  lib,
  ...
}: let
  pluginSpecs = import ./plugins.nix;
  zstylesPre = builtins.readFile ./zstyles-before.zsh;
  zstylesPost = builtins.readFile ./zstyles-after.zsh;

  pluginsDir = ./plugins;
  localPluginFiles = builtins.attrNames (builtins.readDir pluginsDir);
  localPlugins = builtins.filter (name: lib.strings.hasSuffix ".plugin.zsh" name) localPluginFiles;
in {
  home.sessionPath =
    [
      "${config.home.homeDirectory}/.local/bin"
      "${config.home.homeDirectory}/.luarocks/bin"
      "${config.home.homeDirectory}/bin"
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      "${config.home.homeDirectory}/bin/ubuntu-dev-tools"
      "${config.home.homeDirectory}/bin/ubuntu-archive-tools"
      "/snap/bin"
    ];

  programs.zsh = {
    antidote = {
      enable = true;
      package = pkgs.antidote;
      plugins = pluginSpecs;
      useFriendlyNames = false;
    };

    autosuggestion = {
      enable = true;
      strategy = [
        "history"
        "completion"
      ];
    };

    completionInit = ''
      # Use cached completion dump, regenerated on home-manager activation
      autoload -Uz compinit
      compinit -C -d "${config.xdg.cacheHome}/zsh/.zcompdump"
    '';

    defaultKeymap = "emacs";

    dotDir = "${config.xdg.configHome}/zsh";

    enable = true;

    enableCompletion = true;
    enableVteIntegration = true;

    envExtra = ''
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
      size = 20000;
    };

    initContent = lib.mkMerge [
      (lib.mkBefore zstylesPre)
      (lib.mkAfter zstylesPost)
    ];

    plugins =
      map (name: {
        name = lib.removeSuffix ".plugin.zsh" name;
        src = pluginsDir;
      })
      localPlugins;

    sessionVariables =
      {
        VISUAL = "nvim";
        QUILT_PATCHES = "debian/patches";
        # Colourise manpages with `bat`
        # From https://github.com/sharkdp/bat?tab=readme-ov-file#man
        MANPAGER = ''
          sh -c 'sed -u -e \"s/\\x1B\[[0-9;]*m//g; s/.\\x08//g\" | bat -p -lman'
        '';
      }
      // lib.optionalAttrs pkgs.stdenv.isLinux {
        DOCKER_HOST = "unix://\${XDG_RUNTIME_DIR}/podman/podman.sock";
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
      ## Append to history instead of overwriting
      "APPEND_HISTORY"
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

    shellAliases =
      {
        cat = "bat";
        chmod = "chmod -v";
        chown = "chown -v";
        cp = "cp -iv";
        ln = "ln -v";
        mkdir = "mkdir -v";
        mv = "mv -iv";
      }
      // {
        # Add `--one-file-system` flag to prevent accidental cross-filesystem
        # deletion
        rm =
          if pkgs.stdenv.isLinux
          then "rm -v --one-file-system"
          else "rm -v";
      };

    syntaxHighlighting.enable = true;
  };

  xdg.configFile = {
    "zsh/functions".source = ./functions;
  };

  home.activation.zshCompletionDump = lib.hm.dag.entryAfter ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p "${config.xdg.cacheHome}/zsh"
    $DRY_RUN_CMD ${pkgs.zsh}/bin/zsh -c '
      autoload -Uz compinit
      compinit -u -d "${config.xdg.cacheHome}/zsh/.zcompdump"
      zcompile "${config.xdg.cacheHome}/zsh/.zcompdump"
    '
  '';
}
