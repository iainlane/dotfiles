{
  inputs,
  config,
  ...
}: let
  # This module sets up Kolide via upstream's flake, and puts the secret in the
  # right place for the launcher to pick up.
  #
  # Put the enrollment secret in:
  #
  #   <dotfiles-secrets>/${config.networking.hostName}/host-kolide.yaml
  #
  # under the `kolide` key.
  #
  # See upstream's README for details on how to extract the secrets from an
  # `.rpm` or `.deb`:
  #
  # - https://github.com/kolide/nix-agent#running-kolide-launcher
  # - https://github.com/kolide/nix-agent#setting-up-your-enrollment-secret
  secretsFile = inputs.secrets + "/${config.networking.hostName}/host-kolide.yaml";
in {
  imports = [
    inputs.kolide-launcher.nixosModules.kolide-launcher
  ];

  services.kolide-launcher.enable = true;

  sops.secrets.kolide = {
    mode = "0600";
    path = "/etc/kolide-k2/secret";
    sopsFile = secretsFile;
  };
}
