{pkgs, ...}: {
  home = {
    stateVersion = "24.05";
    preferXdgDirectories = true;

    language = {
      base = "en_GB.UTF-8";
    };

    # Suppress "Last login" message at terminal startup.
    file.".hushlogin".text = "";

    packages = with pkgs; [
      # Build tools and networking basics.
      cupboard
      curl
      httpie
      pre-commit
      rsync
      wget

      # GNU versions of core utilities. macOS ships BSD variants which have
      # incompatible flags; these provide consistent behaviour across platforms.
      bc
      diffutils
      getopt
      gnugrep
      gnused
      gnutar
      openssh
      presenterm
      python3
      units
      wdiff

      # Archive and compression tools.
      p7zip
      unzip
      zip

      # CLI quality-of-life utilities.
      asciinema
      colordiff
      delta
      dotacat
      dust
      fastfetch
      fd
      curlie
      doggo
      duf
      lsof
      moreutils
      procs
      pv
      rename
      sd
      tree

      # Networking and system monitoring tools.
      bandwhich
      cyme
      gping
      mtr
      subnetcalc

      lua.pkgs.luacheck
    ];
  };

  programs.home-manager.enable = true;

  xdg.enable = true;
}
