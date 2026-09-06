{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
  ];

  boot = {
    # Pin to 6.18 until the CrowdStrike Falcon sensor supports kernel 6.19's
    # `sockaddr_unsized` BPF type change. Sensor 7.33 fails to load its BPF
    # probes because the BTF types no longer match: it expects
    # `struct sockaddr *` while the kernel now has `struct sockaddr_unsized *`.
    kernelPackages = lib.mkForce pkgs.linuxPackages_6_18;

    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "thunderbolt"
      "usb_storage"
      "sd_mod"
    ];
    kernelModules = ["kvm-amd"];
    kernelParams = [
      "amdgpu.ppfeaturemask=0xfff7ffff"
      "threadirqs"
    ];
  };

  hardware = {
    enableRedistributableFirmware = true;
    sensor.iio.enable = false;
    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings.General.Experimental = true;
    };
  };

  services = {
    fwupd.enable = true;
    fprintd.enable = true;
    hardware.bolt.enable = true;
    smartd.enable = true;
    auto-cpufreq = {
      enable = true;
      settings = {
        battery = {
          governor = "powersave";
          turbo = "never";
        };
        charger = {
          governor = "performance";
          turbo = "auto";
        };
      };
    };
    tlp.enable = lib.mkForce false;
    power-profiles-daemon.enable = lib.mkForce false;

    logind.settings.Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchExternalPower = "suspend";
      HandleLidSwitchDocked = "suspend";
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
    priority = 100;
  };

  environment.systemPackages = with pkgs; [
    framework-tool
    fw-ectool
  ];
}
