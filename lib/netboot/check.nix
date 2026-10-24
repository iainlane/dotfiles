{lib}: {pkgs, ...}: let
  hosts = {
    stable = {
      system = "x86_64-linux";
      channel = "stable";
    };
    unstable = {
      system = "x86_64-linux";
      channel = "unstable";
    };
    arm = {
      system = "aarch64-linux";
      channel = "unstable";
    };
  };
  substitutersModule = {nix.settings.substituters = ["https://fixture.invalid"];};
  hostToplevels = {
    stable = "/host/stable";
    unstable = "/host/unstable";
    arm = "/host/arm";
    unrelated = throw "The installer forced an unrelated host.";
  };
  mkPkgs = channel: system: {
    lib = lib // {version = "26.05";};
    linkFarm = name: entries: {inherit channel system name entries;};
    writeText = name: text: {
      outPath = "/text/${name}";
      inherit text;
    };
    callPackage = path: args: {inherit channel system path args;};
    syslinux = "/syslinux/${channel}/${system}";
    nix = "/nix-command";
    pixiecore = "/pixiecore";
    writeShellApplication = args: {
      outPath = "/app/${system}/${args.name}";
      meta.mainProgram = args.name;
    };
  };
  mkNixpkgs = channel: {
    outPath = "/nixpkgs/${channel}";
    lib =
      lib
      // {
        nixosSystem = {
          system,
          modules,
          ...
        }:
          assert lib.elemAt modules 2 == substitutersModule; {
            config = {
              system = {
                build = {
                  kernel = "/kernel/${channel}/${system}";
                  toplevel = "/installer/${channel}/${system}";
                  netbootRamdisk = "/ramdisk/${channel}/${system}";
                  netbootIpxeScript = "/ipxe/${channel}/${system}";
                };
                boot.loader.kernelFile = "kernel";
              };
              boot.kernelParams = ["console=tty0"];
              image.baseName = "fixture";
              isoImage = {
                contents = [{source = "/efi/${channel}/${system}";}];
                storeContents = ["/installer/${channel}/${system}"] ++ ((lib.last modules).isoImage.storeContents or []);
                compressImage = false;
                volumeID = "FIXTURE";
                squashfsCompression = "zstd";
              };
            };
          };
      };
  };
  subject =
    import ./default.nix {
      inputs = {
        nixpkgs = mkNixpkgs "unstable";
        nixpkgs-stable = mkNixpkgs "stable";
        self.outPath = "/fixture/source";
      };
    } {
      inherit hostToplevels substitutersModule;
      nixosHosts = hosts;
      withSystem = system: f:
        f {
          pkgs = mkPkgs "unstable" system;
          pkgs-stable = mkPkgs "stable" system;
        };
    };
  packagesFor = system:
    subject.packagesForSystem {
      pkgs = mkPkgs "unstable" system;
      pkgs-stable = mkPkgs "stable" system;
      platform = lib.systems.elaborate system;
    };
  systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
  matrix = lib.genAttrs systems (system: {
    packages = lib.attrNames (packagesFor system);
    apps = lib.attrNames (subject.appsForSystem {pkgs = mkPkgs "unstable" system;});
  });
  image = system: name: let
    package = (packagesFor system).${"${name}-iso"};
  in {
    inherit (package) channel system path;
    inherit (package.args) squashfsContents bootable efiBootable usbBootable;
  };
  actual = {
    inherit matrix;
    images = [
      (image "aarch64-darwin" "stable")
      (image "aarch64-darwin" "unstable")
      (image "aarch64-darwin" "arm")
      (image "aarch64-linux" "arm")
      (image "aarch64-linux" "stable")
      (image "aarch64-linux" "unstable")
      (image "x86_64-linux" "arm")
    ];
    stableNetboot = (packagesFor "x86_64-linux").stable-netboot-installer;
  };
  expected = {
    matrix = {
      aarch64-darwin = {
        packages = ["arm-iso" "stable-iso" "unstable-iso"];
        apps = ["arm-netboot" "stable-netboot" "unstable-netboot"];
      };
      aarch64-linux = {
        packages = ["arm-iso" "arm-iso-contents" "arm-netboot-installer" "stable-iso" "unstable-iso"];
        apps = ["arm-netboot" "stable-netboot" "unstable-netboot"];
      };
      x86_64-linux = {
        packages = ["arm-iso" "stable-iso" "stable-iso-contents" "stable-netboot-installer" "unstable-iso" "unstable-iso-contents" "unstable-netboot-installer"];
        apps = ["arm-netboot" "stable-netboot" "unstable-netboot"];
      };
    };
    images = [
      {
        channel = "stable";
        system = "aarch64-darwin";
        path = "/nixpkgs/stable/nixos/lib/make-iso9660-image.nix";
        squashfsContents = ["/installer/stable/x86_64-linux" "/host/stable"];
        bootable = false;
        efiBootable = true;
        usbBootable = true;
      }
      {
        channel = "unstable";
        system = "aarch64-darwin";
        path = "/nixpkgs/unstable/nixos/lib/make-iso9660-image.nix";
        squashfsContents = ["/installer/unstable/x86_64-linux" "/host/unstable"];
        bootable = false;
        efiBootable = true;
        usbBootable = true;
      }
      {
        channel = "unstable";
        system = "aarch64-darwin";
        path = "/nixpkgs/unstable/nixos/lib/make-iso9660-image.nix";
        squashfsContents = ["/installer/unstable/aarch64-linux" "/host/arm"];
        bootable = false;
        efiBootable = true;
        usbBootable = true;
      }
      {
        channel = "unstable";
        system = "aarch64-linux";
        path = "/nixpkgs/unstable/nixos/lib/make-iso9660-image.nix";
        squashfsContents = ["/installer/unstable/aarch64-linux" "/host/arm"];
        bootable = false;
        efiBootable = true;
        usbBootable = true;
      }
      {
        channel = "stable";
        system = "aarch64-linux";
        path = "/nixpkgs/stable/nixos/lib/make-iso9660-image.nix";
        squashfsContents = ["/installer/stable/x86_64-linux" "/host/stable"];
        bootable = false;
        efiBootable = true;
        usbBootable = true;
      }
      {
        channel = "unstable";
        system = "aarch64-linux";
        path = "/nixpkgs/unstable/nixos/lib/make-iso9660-image.nix";
        squashfsContents = ["/installer/unstable/x86_64-linux" "/host/unstable"];
        bootable = false;
        efiBootable = true;
        usbBootable = true;
      }
      {
        channel = "unstable";
        system = "x86_64-linux";
        path = "/nixpkgs/unstable/nixos/lib/make-iso9660-image.nix";
        squashfsContents = ["/installer/unstable/aarch64-linux" "/host/arm"];
        bootable = false;
        efiBootable = true;
        usbBootable = true;
      }
    ];
    stableNetboot = {
      name = "stable-netboot-installer";
      channel = "stable";
      system = "x86_64-linux";
      entries = [
        {
          name = "bzImage";
          path = "/kernel/stable/x86_64-linux/kernel";
        }
        {
          name = "cmdline";
          path = {
            outPath = "/text/stable-netboot-cmdline";
            text = "init=/installer/stable/x86_64-linux/init console=tty0";
          };
        }
        {
          name = "initrd";
          path = "/ramdisk/stable/x86_64-linux/initrd";
        }
        {
          name = "netboot.ipxe";
          path = "/ipxe/stable/x86_64-linux/netboot.ipxe";
        }
      ];
    };
  };
in {
  installer-contracts = assert lib.assertMsg (actual == expected) "Installer outputs differ from the expected platform and channel matrix.";
    pkgs.runCommandLocal "installer-contracts" {} "touch $out";

  build-iso-script =
    pkgs.runCommandLocal "build-iso-script" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.diffutils];
    } ''
      bash ${../../scripts/build-iso.test.bash} \
        ${../../scripts/build-iso.bash} \
        ${../../scripts/lib/just-common.bash}
      touch "$out"
    '';
}
