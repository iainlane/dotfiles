{config, ...}: {
  flake.features.base = {
    os.nixos = {
      includes = [config.flake.features.borgmatic];

      homeManager = {pkgs, ...}: {
        home.packages = import ./linux-packages.nix pkgs;
      };
    };

    nixos = {
      users.groups.ssh = {};

      services.nixseparatedebuginfod2.enable = true;

      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
        settings = {
          PermitRootLogin = "no";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
        extraConfig = "AllowGroups ssh";
      };
    };
  };
}
