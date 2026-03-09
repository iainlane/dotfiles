{
  hostname = "bonington";
  os = "nixos";
  arch = "x86_64";
  channel = "stable";
  stateVersion = "25.05";
  profiles = [
    "base"
    "desktop"
    "development"
    "containers"
  ];
}
