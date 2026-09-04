{
  config,
  pkgs,
  ...
}: let
  systemManagerEnv = "/etc/${config.environment.etc."profile.d/system-manager-path.sh".target}";
in {
  environment = {
    etc = {
      # zsh on non-NixOS sources /etc/zshenv for all shells (including SSH
      # logins) before user-level .zshenv, and reads nothing that pulls in
      # /etc/profile. system-manager writes the PATH and variables for its
      # own packages as a profile.d snippet, which bash picks up and zsh
      # never would, so source it from here.
      #
      # TERMINFO_DIRS goes alongside it so Home Manager's TERM reset does
      # not error for xterm-ghostty. Both run once per shell tree: zshenv
      # is read again by every nested zsh, and each would prepend afresh.
      "zshenv".text = ''
        if [ -z "''${__SYSTEM_MANAGER_ENV_DONE-}" ]; then
          export __SYSTEM_MANAGER_ENV_DONE=1

          export TERMINFO_DIRS="/run/system-manager/sw/share/terminfo:''${TERMINFO_DIRS:-/usr/share/terminfo}"

          if [ -r ${systemManagerEnv} ]; then
            . ${systemManagerEnv}
          fi
        fi
      '';

      # Keep TERMINFO_DIRS across sudo boundaries.
      "sudoers.d/terminfo" = {
        source = pkgs.writeText "sudoers-terminfo" ''
          Defaults env_keep += "TERMINFO_DIRS"
        '';
        mode = "0440";
      };
    };

    systemPackages = [pkgs.ghostty.terminfo];
  };
}
