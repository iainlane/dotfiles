{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    inputs.nixos-hardware.nixosModules.framework-13-ai-300
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
    ];
  };

  hardware = {
    enableRedistributableFirmware = true;
    sensor.iio.enable = false;
    bluetooth.enable = true;
    bluetooth.powerOnBoot = true;
  };

  services = {
    fwupd.enable = true;
    fprintd.enable = true;
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

  services.logind = {
    lidSwitch = "suspend";
    lidSwitchExternalPower = "suspend";
    lidSwitchDocked = "suspend";
  };

  environment.systemPackages = with pkgs; [
    framework-tool
    fw-ectool
  ];
}
