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

    specialisation.updated.configuration.services.falcon-sensor.traceLevel = "err";

    virtualisation = {
      memorySize = 4096;
      vlans = lib.mkForce [];
      qemu.networkingOptions = lib.mkForce ["-nic none"];
    };
  };

  testScript = {nodes, ...}: let
    staging = builtins.head nodes.machine.systemd.services.falcon-sensor.serviceConfig.ExecStartPre;
    updated = nodes.machine.specialisation.updated.configuration.system.build.toplevel;
  in ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    assert machine.succeed("ls /sys/class/net").split() == ["lo"]
    assert machine.succeed("uname -r").strip() == "${kernelPackages.kernel.modDirVersion}"

    def installation_state():
        return {
            "contents": machine.succeed("cat /opt/CrowdStrike/install-test/registration"),
            "metadata": machine.succeed(
                "stat -Lc '%U:%G:%a' /opt/CrowdStrike/install-test "
                "/opt/CrowdStrike/install-test/registration /opt/CrowdStrike/falcond"
            ).splitlines(),
        }

    expected_state = {
        "contents": "registered",
        "metadata": ["nobody:nogroup:700", "nobody:nogroup:600", "root:root:750"],
    }

    with subtest("staging preserves sensor state"):
        machine.succeed("${staging}")
        machine.succeed(
            "install -d -m 0700 -o nobody -g nogroup /opt/CrowdStrike/install-test",
            "printf registered > /opt/CrowdStrike/install-test/registration",
            "chown nobody:nogroup /opt/CrowdStrike/install-test/registration",
            "chmod 0600 /opt/CrowdStrike/install-test/registration",
            "${staging}",
        )
        assert installation_state() == expected_state

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

    with subtest("staging refuses a running sensor"):
        output = machine.fail("${staging} 2>&1")
        assert "CrowdStrike Falcon is running; reboot before replacing its files." in output
        assert installation_state() == expected_state

    with subtest("switching leaves the running sensor unchanged"):
        before = machine.succeed(
            "systemctl show falcon-sensor.service -p MainPID -p ActiveEnterTimestampMonotonic"
        )
        machine.succeed("${updated}/bin/switch-to-configuration test")
        after = machine.succeed(
            "systemctl show falcon-sensor.service -p MainPID -p ActiveEnterTimestampMonotonic"
        )
        assert after == before
        machine.wait_for_unit("falcon-sensor.service")
  '';
}
