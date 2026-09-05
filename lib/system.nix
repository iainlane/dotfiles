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
  }: {
    inherit inputs hostConfig username;
    mcp = mcpByChannel.${hostConfig.channel};
    pkgs-unstable = channel.unstable;
  };
}
