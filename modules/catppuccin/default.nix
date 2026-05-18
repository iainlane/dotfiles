_: let
  selectedCatppuccin = {
    hostConfig,
    inputs,
    ...
  }:
    if (hostConfig.channel or "unstable") == "stable"
    then inputs.catppuccin-stable
    else inputs.catppuccin;

  defaults = {lib, ...}: {
    catppuccin.flavor = lib.mkDefault "latte";
  };

  homeManagerModule = args: {
    imports = [
      defaults
      (selectedCatppuccin args).homeModules.catppuccin
    ];
  };

  nixosModule = args: {
    imports = [
      defaults
      (selectedCatppuccin args).nixosModules.catppuccin
    ];
  };
in {
  flake.modules.catppuccin = {
    homeManagerModules = [homeManagerModule];
    nixosModules = [nixosModule];
  };
}
