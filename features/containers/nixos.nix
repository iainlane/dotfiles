{
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # podman's `docker` compatibility shim prints a notice saying it is
  # emulating docker on every invocation unless this file exists.
  environment.etc."containers/nodocker".text = "";
}
