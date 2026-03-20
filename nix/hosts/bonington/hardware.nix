{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
  ];

  # Pin to 6.18 until CrowdStrike Falcon sensor supports kernel 6.19's
  # sockaddr_unsized BPF type change (sensor 7.33 fails to load BPF probes
  # due to BTF type mismatch: struct sockaddr * vs struct sockaddr_unsized *).
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_6_18;

  boot = {
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
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
    HandleLidSwitchDocked = "suspend";
  };

  environment.systemPackages = with pkgs; [
    framework-tool
    fw-ectool
  ];
}
