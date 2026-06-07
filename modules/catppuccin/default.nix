_: let
  isStable = hostConfig: (hostConfig.channel or "unstable") == "stable";

  selectedCatppuccin = {
    hostConfig,
    inputs,
    ...
  }:
    if isStable hostConfig
    then inputs.catppuccin-stable
    else inputs.catppuccin;

  defaults = {lib, ...}: {
    catppuccin.flavor = lib.mkDefault "latte";
  };

  # The unstable channel is moving to `catppuccin.autoEnable` for port
  # enrolment, with `catppuccin.enable` becoming a global on/off toggle. Set
  # both explicitly to silence the deprecation warning. Theming is configured
  # per-module rather than through the ports, so auto-enrolment stays off. The
  # stable channel has no `autoEnable` option, so this is scoped to unstable.
  autoEnableDefaults = {lib, ...}: {
    catppuccin = {
      enable = lib.mkDefault true;
      autoEnable = lib.mkDefault false;
    };
  };

  channelDefaults = args:
    if isStable args.hostConfig
    then []
    else [autoEnableDefaults];

  homeManagerModule = args: {
    imports =
      [
        defaults
        (selectedCatppuccin args).homeModules.catppuccin
      ]
      ++ channelDefaults args;
  };

  nixosModule = args: {
    imports =
      [
        defaults
        (selectedCatppuccin args).nixosModules.catppuccin
      ]
      ++ channelDefaults args;
  };
in {
  flake.modules.catppuccin = {
    homeManagerModules = [homeManagerModule];
    nixosModules = [nixosModule];
  };
}
