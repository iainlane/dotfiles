{
  inputs,
  pkgs,
  kernelPackages,
}:
pkgs.testers.runNixOSTest {
  name = "falcon-kernel";

  nodes.machine = {lib, ...}: {
    imports = [./service.nix];
    _module.args.inputs = inputs;

    boot.kernelPackages = kernelPackages;
    networking.useDHCP = false;

    services.falcon-sensor = {
      enable = true;
      cidFile = pkgs.writeText "falcon-test-cid" "00000000000000000000000000000000-00";
    };
    systemd.services.falcon-sensor.wantedBy = lib.mkForce [];

    virtualisation = {
      memorySize = 4096;
      vlans = lib.mkForce [];
      qemu.networkingOptions = lib.mkForce ["-nic none"];
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    assert machine.succeed("ls /sys/class/net").split() == ["lo"]
    assert machine.succeed("uname -r").strip() == "${kernelPackages.kernel.modDirVersion}"

    machine.succeed("systemctl start falcon-sensor.service")
    machine.wait_for_unit("falcon-sensor.service")

    try:
        machine.wait_until_succeeds(
            "/opt/CrowdStrike/falconctl -g --rfm-state | grep -Ex 'rfm-state=(false|true)\\.'",
            timeout=60,
        )
        assert machine.succeed("/opt/CrowdStrike/falconctl -g --rfm-state").strip() == "rfm-state=false."
        assert machine.succeed("/opt/CrowdStrike/falconctl -g --backend").strip() == "backend=bpf."
    except Exception:
        print(machine.execute("/opt/CrowdStrike/falconctl -g --version --rfm-state --rfm-reason"))
        print(machine.execute("journalctl -b -u falcon-sensor.service --no-pager"))
        raise
  '';
}
