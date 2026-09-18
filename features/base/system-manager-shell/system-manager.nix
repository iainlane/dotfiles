{
  config,
  pkgs,
  ...
}: let
  systemManagerEnv = "/etc/${config.environment.etc."profile.d/system-manager-path.sh".target}";
in {
  environment = {
    etc = {
      # On non-NixOS systems, zsh reads /etc/zshenv before the user's
      # .zshenv, including for SSH logins, but does not read /etc/profile.
      # Source system-manager's profile.d script here to set PATH and the
      # other environment variables for system-manager packages.
      #
      # Set TERMINFO_DIRS before Home Manager resets the terminal so the
      # reset can find the xterm-ghostty terminfo entry.
      #
      # Child zsh processes also read /etc/zshenv. They inherit the exported
      # guard, so they skip this setup and do not prepend the paths again.
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
