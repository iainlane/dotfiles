{
  inputs,
  lib,
  pkgs,
  config,
  username,
  hostConfig,
  nixpkgsConfig,
  ...
}: {
  imports = [
    inputs.nix-system-graphics.systemModules.default
  ];

  # nixpkgs' config/nix.nix now declares nix.enable and nix.package itself,
  # which collides with the declarations in system-manager's shim, so drop
  # the shim. The shim's config side was inactive: it sat behind
  # `mkIf config.nix.enable` and nothing enabled it.
  disabledModules = ["${inputs.system-manager}/nix/modules/upstream/nixpkgs/nix.nix"];

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

    # nixpkgs' config/nix.nix hides the nixbld users from display managers.
    # system-manager imports that module without the display-manager one, so
    # the option has to exist for the definition to merge. Nothing reads it.
    services.displayManager.hiddenUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Ignored; declared so nixpkgs' config/nix.nix evaluates under system-manager";
    };
  };

  config = {
    # nixpkgs' default is true, under which config/nix.nix writes
    # /etc/nix/nix.conf and creates the nixbld users. Determinate Nix owns
    # both on these hosts; see the nix.custom.conf entry below.
    nix.enable = false;

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

        # Ubuntu's systemd-resolved disables mDNS in favour of Avahi.
        # Re-enable it so .local resolution works without Avahi.
        "systemd/resolved.conf.d/01-enable-mdns.conf".text = ''
          [Resolve]
          MulticastDNS=yes
        '';

        # Determinate Nix owns /etc/nix/nix.conf and !includes nix.custom.conf.
        # Under system-manager nothing generates the nix.conf entry, so render
        # nix.settings into the custom file ourselves.
        "nix/nix.custom.conf".text = let
          renderValue = value:
            if lib.isBool value
            then lib.boolToString value
            else if lib.isList value
            then lib.concatMapStringsSep " " toString value
            else toString value;
        in
          lib.concatStringsSep "\n"
          (lib.mapAttrsToList (name: value: "${name} = ${renderValue value}") config.nix.settings)
          + "\n";
      };
    };

    nix.settings = {
      auto-optimise-store = true;
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
