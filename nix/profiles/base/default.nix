_: {
  flake.homeManagerModules.base = {
    pkgs,
    lib,
    inputs,
    system,
    modulesPath,
    flakePath,
    ...
  }: {
    imports = [
      inputs.nix-index-database.homeModules.nix-index
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
          getopt
          gnugrep
          gnused
          gnutar
          openssh
          presenterm
          wdiff

          # CLI quality-of-life utilities.
          asciinema
          delta
          dotacat
          dust
          fastfetch
          fd
          curlie
          doggo
          duf
          moreutils
          procs
          rename
          sd

          # Networking and system monitoring tools.
          bandwhich
          cyme
          gping
          mtr
          subnetcalc

          lua.pkgs.luacheck
        ]
        ++ lib.optionals pkgs.stdenv.isLinux [deckmaster];
    };

    programs = {
      gh = {
        enable = true;
        gitCredentialHelper.enable = true;
        settings.gitProtocol = "https";
      };

      home-manager.enable = true;

      nh = {
        enable = true;
        flake = flakePath;
        # v4.3.0-beta1 fixes path quoting bug with spaces in PATH
        # https://github.com/nix-community/nh/commit/4ae85ee
        package = inputs.nh.packages.${system}.default;
      };

      # nix-index provides `nix-locate` for finding which package provides a file.
      # The database is pre-built by nix-index-database, so no local indexing needed.
      nix-index = {
        enable = true;
        # Use comma (`,`) to run packages without installing them instead of
        # the command-not-found handler which can be slow.
        enableZshIntegration = false;
      };

      # Comma lets you run programs from nixpkgs without installing them:
      # `, cowsay hello` runs cowsay from nixpkgs
      nix-index-database.comma.enable = true;
    };

    xdg = {
      enable = true;

      # Ensure standalone nix commands (e.g. `nix shell`) see the same nixpkgs
      # config as our flakes, so we can use unfree packages. The `pkgs.config`
      # object contains functions and their metadata which can't be
      # serialised, so we filter those out.
      configFile."nixpkgs/config.nix".text = let
        isPlainValue = v:
          !builtins.isFunction v
          && !(builtins.isAttrs v && v ? __functionArgs);
      in
        lib.generators.toPretty {} (lib.filterAttrsRecursive (_: isPlainValue) pkgs.config);
    };
  };
}
