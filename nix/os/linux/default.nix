{
  inputs,
  lib,
  pkgs,
  username,
  hostConfig,
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
    environment.etc = {
      "apparmor.d/nix-chrome".text = ''
        abi <abi/4.0>,
        include <tunables/global>

        profile nix_chrome /nix/store/**/bin/google-chrome-stable flags=(unconfined) {
          userns,
          @{exec_path} mr,

          # Site-specific additions and overrides. See local/README for details.
          include if exists <local/chrome>
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

    system-graphics.enable = true;

    users.users.${username} = {
      name = username;
      home = hostConfig.homeDirectory;
    };
  };
}
