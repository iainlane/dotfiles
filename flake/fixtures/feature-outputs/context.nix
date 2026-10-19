{hostConfig}: {pkgs, ...}: {
  ${hostConfig.name} = pkgs.hello;
}
