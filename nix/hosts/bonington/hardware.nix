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
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "thunderbolt"
      "usb_storage"
      "sd_mod"
    ];
    kernelModules = ["kvm-amd"];
    kernelParams = [
      "mem_sleep_default=s2idle"
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
