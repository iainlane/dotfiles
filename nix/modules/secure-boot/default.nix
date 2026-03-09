_: let
  secureBoot = {
    lib,
    config,
    pkgs,
    inputs,
    ...
  }: let
    cfg = config.dotfiles.secureBoot;
  in {
    disabledModules = [
      "system/boot/systemd/tpm2.nix"
    ];

    imports = [
      "${inputs.nixpkgs-measured-boot}/nixos/modules/system/boot/systemd/tpm2.nix"
    ];

    options.dotfiles.secureBoot = {
      luksDevice = lib.mkOption {
        type = lib.types.str;
        default = "crypted";
        description = "LUKS device name matching the disko config.";
      };
      pcrSigningKeyDir = lib.mkOption {
        type = lib.types.str;
        default = "/etc/secureboot/keys";
        description = "Directory containing PCR signing keys.";
      };
      pcrlockEnable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable pcrlock sharding (PCRs 0-7).";
      };
    };

    config = {
      boot = {
        loader.systemd-boot.enable = lib.mkForce false;

        lanzaboote = {
          enable = true;
          pkiBundle = "/etc/secureboot";
          pcrSigning = {
            enable = true;
            privateKeyFile = "${cfg.pcrSigningKeyDir}/pcr-signing-private.pem";
            publicKeyFile = "${cfg.pcrSigningKeyDir}/pcr-signing-public.pem";
          };
        };

        initrd = {
          systemd = {
            enable = true;
            tpm2.enable = true;
            pcrlock.enable = cfg.pcrlockEnable;
          };
          luks.devices.${cfg.luksDevice} = {
            crypttabExtraOpts = ["tpm2-device=auto"];
          };
        };
      };

      security.tpm2 = {
        enable = true;
        tctiEnvironment.enable = true;
      };

      systemd.pcrlock.enable = cfg.pcrlockEnable;

      environment.systemPackages = with pkgs; [
        sbctl
        tpm2-tools
      ];
    };
  };
in {
  flake.modules."secure-boot" = {
    nixosModules = [secureBoot];
  };
}
