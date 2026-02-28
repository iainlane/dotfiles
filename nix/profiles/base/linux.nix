_: {
  flake.profiles.base.os.linux.homeManagerModule = {
    lib,
    pkgs,
    ...
  }: {
    home = {
      packages = with pkgs; [
        lurk
      ];

      # Home Manager's generic Linux target sources `nix.sh`, which may omit
      # daemon-profile paths on multi-user installs. Prefer `nix-daemon.sh` when
      # available so non-interactive shells get the same Nix PATH setup.
      sessionVariablesExtra = lib.mkAfter ''
        if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
          . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        fi
      '';
    };

    targets.genericLinux.enable = true;
  };
}
