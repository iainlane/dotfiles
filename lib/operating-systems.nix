# Everything that varies by operating system and is not code: the module
# system that builds the host's system configuration, the flake output that
# configuration appears under, the directory the user's home lives in, and the
# second half of the host's Nix system string. To add an operating system, add
# an entry here, an adapter under `os/`, the activation call in
# `flake/parts/deploy.nix` and the derivation-path accessor in
# `flake/parts/checks/host-evaluation.nix`.
{
  nixos = {
    systemClass = "nixos";
    outputName = "nixosConfigurations";
    homeBaseDir = "/home";
    systemSuffix = "linux";
  };

  "generic-linux" = {
    systemClass = "systemManager";
    outputName = "systemConfigs";
    homeBaseDir = "/home";
    systemSuffix = "linux";
  };

  darwin = {
    systemClass = "darwin";
    outputName = "darwinConfigurations";
    homeBaseDir = "/Users";
    systemSuffix = "darwin";
  };
}
