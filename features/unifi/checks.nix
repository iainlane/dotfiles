{pkgs, ...}: let
  container = import ./container.nix {
    cfg = {
      listenAddress = "192.0.2.1";
      webPort = 11443;
      extraPorts = [];
    };
    firmwarePlatform = "fixture";
    image = "fixture";
    network = "fixture";
    quadlet.mounts = mounts: mounts;
    serverVersion = "fixture";
    uuidBuilder = "/fixture";
    volumes = [];
  };
  health = container.containerConfig;
in {
  unifi-readiness =
    pkgs.runCommandLocal "unifi-readiness-test" {
      nativeBuildInputs = [pkgs.python3];
      startupCommand = health.healthStartupCmd or health.healthCmd;
    } ''
      python3 <<'PY'
      import json
      import os
      from pathlib import Path
      import subprocess
      import tempfile

      with tempfile.TemporaryDirectory() as directory:
          root = Path(directory)
          log = root / "commands.jsonl"
          stub = """#!${pkgs.python3}/bin/python3
      import json
      import os
      from pathlib import Path
      import sys

      command = Path(sys.argv[0]).name
      with open(os.environ["COMMAND_LOG"], "a") as log:
          log.write(json.dumps([command, *sys.argv[1:]]) + "\\n")
      sys.exit(int(os.environ[command.upper() + "_STATUS"]))
      """
          for command in ("systemctl", "curl"):
              path = root / command
              path.write_text(stub)
              path.chmod(0o700)

          service_check = ["systemctl", "is-active", "--quiet", "unifi.service"]
          tls_check = [
              "curl", "--fail", "--silent", "--show-error", "--insecure",
              "--max-time", "5", "https://127.0.0.1/api/ping",
          ]
          for service_status, tls_status, expected in (
              (3, 0, (3, [service_check])),
              (0, 22, (22, [service_check, tls_check])),
              (0, 0, (0, [service_check, tls_check])),
          ):
              log.write_text("")
              result = subprocess.run(
                  ["${pkgs.runtimeShell}", "-c", os.environ["startupCommand"]],
                  env={
                      **os.environ,
                      "PATH": str(root),
                      "COMMAND_LOG": str(log),
                      "SYSTEMCTL_STATUS": str(service_status),
                      "CURL_STATUS": str(tls_status),
                  },
                  capture_output=True, text=True, timeout=10,
              )
              actual = (result.returncode, [json.loads(line) for line in log.read_text().splitlines()])
              assert actual == expected, (service_status, tls_status, actual, expected, result.stderr)
      PY

      touch "$out"
    '';
}
