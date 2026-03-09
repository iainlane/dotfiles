{
  hostname = "bonington";
  os = "nixos";
  arch = "x86_64";
  channel = "stable";
  profiles = [
    "base"
    "desktop"
    "development"
    "containers"
  ];
}
