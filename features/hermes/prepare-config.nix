{pkgs}:
pkgs.writeShellApplication {
  name = "hermes-prepare-config";
  runtimeInputs = [pkgs.coreutils];
  text = builtins.readFile ./prepare-config.sh;
}
