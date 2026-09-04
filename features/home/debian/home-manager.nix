{config, ...}: {
  home.sessionPath = [
    "${config.home.homeDirectory}/bin/ubuntu-dev-tools"
    "${config.home.homeDirectory}/bin/ubuntu-archive-tools"
  ];

  programs = {
    git.settings = {
      merge."dpkg-mergechangelogs" = {
        name = "debian/changelog merge driver";
        driver = "dpkg-mergechangelogs -m %O %A %B %A";
      };

      # Git URL shortcuts.

      # Allow gnome:<path> shorthand for SSH URLs; also rewrite git:// to
      # SSH for pushes.
      "url \"ssh://git.gnome.org/git/\"" = {
        insteadOf = "gnome:";
        pushInsteadOf = "git://git.gnome.org/git/";
      };

      # lp: shorthand for Launchpad Git URLs.
      "url \"git+ssh://laney@git.launchpad.net/\"".insteadOf = "lp:";
    };

    zsh.sessionVariables = {
      QUILT_PATCHES = "debian/patches";
    };
  };

  xdg.configFile."zsh/functions".source = ../../base/zsh/functions;
}
