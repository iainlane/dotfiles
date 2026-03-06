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

      # deploy-rs activate-rs invokes `nix-env` by name on remote hosts.
      # Ensure non-interactive SSH sessions can resolve Nix CLI binaries.
      sessionPath = ["/nix/var/nix/profiles/default/bin"];

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

  flake.profiles.base.os.linux.systemManagerModule = {
    lib,
    pkgs,
    ...
  }: {
    config = {
      environment = {
        etc = {
          # zsh on non-NixOS sources /etc/zshenv for all shells (including SSH
          # logins) before user-level .zshenv. Set TERMINFO_DIRS here so
          # Home Manager's TERM reset does not error for xterm-ghostty.
          "zshenv".text = ''
            export TERMINFO_DIRS="/run/system-manager/sw/share/terminfo:''${TERMINFO_DIRS:-/usr/share/terminfo}"
          '';

          # Keep TERMINFO_DIRS across sudo boundaries.
          "sudoers.d/terminfo" = {
            source = pkgs.writeText "sudoers-terminfo" ''
              Defaults env_keep += "TERMINFO_DIRS"
            '';
            mode = "0440";
          };
        };

        pathsToLink = lib.mkAfter ["/share/terminfo"];
        systemPackages = [pkgs.ghostty.terminfo];
      };
    };
  };
}
