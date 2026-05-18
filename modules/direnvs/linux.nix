{lib, ...}: {
  # Playwright's prebuilt Chromium is a glibc-built binary that runs under
  # nix-ld on NixOS. The system-wide nix-ld config only ships libraries that
  # everything needs; everything else must come through `NIX_LD_LIBRARY_PATH` in
  # the shell that launches the browser, so prepend the Chromium runtime
  # libraries here for any direnv that opts into the typescript language.
  config.flake.direnvLanguages.typescript.os.linux.shell = pkgs: let
    chromiumLibraries = with pkgs; [
      alsa-lib
      at-spi2-core
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libgbm
      libx11
      libxcb
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxkbcommon
      libxrandr
      libxshmfence
      nspr
      nss
      pango
      systemd
    ];
  in {
    shellHook = ''
      export NIX_LD_LIBRARY_PATH="${lib.makeLibraryPath chromiumLibraries}''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
    '';
  };
}
