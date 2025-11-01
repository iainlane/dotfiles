_: {
  flake.homeManagerModules.base = {
    pkgs,
    lib,
    mkProfileImports,
    modulesPath,
    ...
  }:
  # Baseline user environment shared by every host.
  {
    imports = mkProfileImports ./. [
      ./colours.nix
      (modulesPath + /git)
      (modulesPath + /scripts)
      (modulesPath + /zsh)
      (modulesPath + /neovim)
      (modulesPath + /starship)
      (modulesPath + /cli-tools)
    ];

    home = {
      stateVersion = "24.05";

      language = {
        base = "en_GB.UTF-8";
      };

      # Suppress "Last login" message at terminal startup.
      file.".hushlogin".text = "";

      packages = with pkgs;
        [
          # Build tools and networking basics.
          curl
          httpie
          pre-commit
          rsync
          wget

          # GNU versions of core utilities. macOS ships BSD variants which have
          # incompatible flags; these provide consistent behaviour across platforms.
          diffutils
          gnugrep
          gnused
          gnutar
          openssh
          presenterm
          wdiff

          # CLI quality-of-life utilities.
          delta
          dust
          fd
          curlie
          doggo
          duf

          lua.pkgs.luacheck
        ]
        ++ lib.optionals pkgs.stdenv.isLinux [deckmaster];
    };

    programs.gh = {
      enable = true;
      gitCredentialHelper.enable = true;
      settings.gitProtocol = "https";
    };

    programs.home-manager.enable = true;

    xdg.enable = true;
  };
}
