{hostConfig, ...}: {
  home.file.".motd".text = hostConfig.motd;
}
