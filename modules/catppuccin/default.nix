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

  # `catppuccin.sources.<port>` is the built port package; the per-app modules
  # read their themes from it, which is IFD. Point the ports we theme at
  # native-fetched inputs that mirror the installed layout (themes flattened to
  # the package root), so those reads happen against an evaluation-time path.
  # The `sources` option applies `recursiveUpdate` over the defaults, so a
  # string value replaces just that port and leaves the rest untouched.
  sourceOverrides = {inputs, ...}: {
    catppuccin.sources = {
      bottom = "${inputs.catppuccin-bottom}/themes";
      palette = "${inputs.catppuccin-palette}";
      gemini-cli = "${inputs.catppuccin-gemini-cli}/themes";
    };
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
        (sourceOverrides args)
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
