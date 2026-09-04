{
  lib,
  pkgs,
  ...
}: {
  home = {
    packages = import ./linux-packages.nix pkgs;

    # deploy-rs activate-rs invokes `nix-env` by name on remote hosts.
    # Ensure non-interactive SSH sessions can resolve Nix CLI binaries. It
    # goes last so it never shadows the user's own directories.
    sessionPath = lib.mkAfter ["/nix/var/nix/profiles/default/bin"];

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
}
