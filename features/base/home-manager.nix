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

      # The GNU versions of core utilities, plus util-linux's `getopt`. macOS
      # ships BSD variants whose flags differ, so these keep the behaviour the
      # same on every platform.
      bc
      diffutils
      getopt
      gnugrep
      gnused
      gnutar

      # Text and numeric tools that macOS does not ship at all.
      units
      wdiff

      openssh
      presenterm
      python3

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
