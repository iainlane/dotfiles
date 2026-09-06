{
  inputs,
  config,
  ...
}: let
  # This module enables Kolide from upstream's flake and writes the enrolment
  # secret to /etc/kolide-k2/secret, where the launcher reads it.
  #
  # Put the enrolment secret in:
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
