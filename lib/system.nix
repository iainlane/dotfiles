# Builds the special arguments shared by the NixOS, nix-darwin and
# system-manager adapters, so a module written for one class finds the same
# arguments under the others.
#
# `lib/home.nix` builds the Home Manager arguments.
{inputs}: {
  mkSystemSpecialArgs = {
    hostConfig,
    username,
    mcpByChannel,
    channel,
    modelCatalog,
  }: {
    inherit inputs hostConfig username modelCatalog;
    mcp = mcpByChannel.${hostConfig.channel};
    defaultModels = modelCatalog.defaults;
    pkgs-unstable = channel.unstable;
  };
}
