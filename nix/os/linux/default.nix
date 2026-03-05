{
  inputs,
  lib,
  pkgs,
  username,
  hostConfig,
  nixpkgsConfig,
  ...
}: {
  imports = [
    ./binfmt.nix
    inputs.nix-system-graphics.systemModules.default
    ../../modules/nix/substituters.nix
  ];

  # Define NixOS-specific options for home-manager compatibility with system-manager
  options = {
    i18n.glibcLocales = lib.mkOption {
      type = lib.types.package;
      default = pkgs.glibcLocales;
      description = "Glibc locales package for home-manager compatibility";
    };

    fonts.fontconfig.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable fontconfig for home-manager compatibility";
    };
  };

  config = {
    environment = {
      etc = {
        "apparmor.d/nix-chrome".text = ''
          abi <abi/4.0>,
          include <tunables/global>

          profile nix_chrome /nix/store/**/bin/google-chrome-stable flags=(unconfined) {
            userns,

            # Allow read and mmap with PROT_EXEC on the profile's executable path
            @{exec_path} mr,

            # Site-specific additions and overrides. See local/README for details.
            include if exists <local/chrome>
          }
        '';

        "apparmor.d/bwrap".text = ''
          abi <abi/4.0>,
          include <tunables/global>

          profile bwrap /nix/store/**/bin/bwrap flags=(unconfined) {
            userns,

            # Allow read and mmap with PROT_EXEC on the profile's executable path
            @{exec_path} mr,

            # Site-specific additions and overrides. See local/README for details.
            include if exists <local/bwrap>
          }
        '';

        # Create /etc/containers/nodocker to indicate Docker isn't installed. Some
        # container tools check for this to avoid trying to use the Docker socket.
        "containers/nodocker".text = "";

        # Redirect nix.conf to nix.custom.conf. system-manager will generate nix.conf
        # from nix.settings, but the symlink redirects it to nix.custom.conf which
        # Determinate Nix's managed nix.conf includes via !include directive
        "nix/nix.conf".target = "nix/nix.custom.conf";

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

    # Systemd service to set capabilities on network monitoring tools
    # This replaces security.wrappers which is not supported by system-manager
    systemd.services.set-network-capabilities = {
      description = "Set capabilities on network monitoring tools";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Set capabilities on bandwhich
        if [ -f "${pkgs.bandwhich}/bin/bandwhich" ]; then
          ${pkgs.libcap}/bin/setcap cap_sys_ptrace,cap_dac_read_search,cap_net_raw,cap_net_admin+ep "${pkgs.bandwhich}/bin/bandwhich" || true
        fi

        # Set capabilities on netdiscover
        if [ -f "${pkgs.netdiscover}/bin/netdiscover" ]; then
          ${pkgs.libcap}/bin/setcap cap_net_raw,cap_net_admin+ep "${pkgs.netdiscover}/bin/netdiscover" || true
        fi
      '';
    };

    # Rootless podman needs newuidmap/newgidmap with setuid privileges.
    # system-manager does not expose security.wrappers, so install helpers
    # into /usr/local/libexec/podman at boot.
    systemd.services.install-rootless-uidmap-wrappers = {
      description = "Install setuid uidmap helpers for rootless containers";
      wantedBy = ["sysinit.target"];
      after = ["local-fs.target"];
      before = ["systemd-user-sessions.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0755 /usr/local/libexec/podman
        install -m 4755 -o root -g root ${pkgs.shadow}/bin/newuidmap /usr/local/libexec/podman/newuidmap
        install -m 4755 -o root -g root ${pkgs.shadow}/bin/newgidmap /usr/local/libexec/podman/newgidmap
      '';
    };

    # `system-manager` requires `nixpkgs.hostPlatform` to be set.
    nixpkgs.hostPlatform = lib.mkDefault "${hostConfig.arch}-linux";
    nixpkgs.config = lib.mkDefault nixpkgsConfig;

    system-graphics =
      {
        enable = true;
        package = pkgs.mesa;
      }
      // lib.optionalAttrs (hostConfig.arch == "x86_64") {
        package32 = pkgs.pkgsi686Linux.mesa;
      };

    users.users.${username} = {
      name = username;
      group = username;
      home = hostConfig.homeDirectory;
      isNormalUser = true;
      shell = pkgs.zsh;
      # system-manager's option set does not include `programs.zsh`, so opt out
      # of the NixOS shell-program assertion while still using zsh as login shell.
      ignoreShellProgramCheck = true;
    };

    users.groups.${username} = {};
  };
}
