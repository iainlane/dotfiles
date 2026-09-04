{
  networking.firewall.trustedInterfaces = ["tailscale0"];

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
  };

  systemd.services.tailscaled.serviceConfig.Environment = [
    "TS_DEBUG_FIREWALL_MODE=nftables"
  ];
}
