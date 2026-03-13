let
  btrfsMountOptions = ["compress=zstd" "discard=async" "noatime" "space_cache=v2" "ssd"];
  dataSubvolumes = builtins.mapAttrs (_: mountpoint: {
    inherit mountpoint;
    mountOptions = btrfsMountOptions;
  }) {
    "@root" = "/";
    "@home" = "/home";
    "@nix" = "/nix";
    "@log" = "/var/log";
  };
in {
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-WD_BLACK_SN7100_1TB_25435D803157";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = ["umask=0077"];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "crypted";
              settings.allowDiscards = true;
              content = {
                type = "btrfs";
                extraArgs = ["-f"];
                subvolumes = dataSubvolumes // {
                  "@swap" = {
                    mountpoint = "/.swapvol";
                    swap.swapfile.size = "8G";
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
