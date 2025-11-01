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

    environment.etc = {
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
    };

    # Provide a default platform that hosts can override. `system-manager`
    # requires `nixpkgs.hostPlatform` to be set, so we default to `x86_64-linux`.
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    nixpkgs.config = lib.mkDefault nixpkgsConfig;

    system-graphics = {
      enable = true;
      package = pkgs.mesa;
      package32 = pkgs.pkgsi686Linux.mesa;
    };

    users.groups.${username} = {};

    users.users.${username} = {
      name = username;
      group = username;
      home = hostConfig.homeDirectory;
      isNormalUser = true;

      # This module expects the shell to be installed by NixOS, but we install
      # it via home-manager.
      ignoreShellProgramCheck = true;
      shell = pkgs.zsh;
    };
  };
}
