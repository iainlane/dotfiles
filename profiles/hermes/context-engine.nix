# The LCM context engine: swaps the default compressor for the hermes-lcm
# plugin and the Python packages it needs.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
in {
  config = lib.mkIf (cfg.enable && cfg."context-engine" == "lcm") {
    services.hermes-agent = {
      extraPlugins.hermes-lcm = inputs.hermes-lcm;
      # hermes-lcm uses tiktoken for exact token counts and regex for
      # message ignore patterns.
      extraPythonPackages = [
        pkgs.python312Packages.tiktoken
        pkgs.python312Packages.regex
      ];
      enabledPlugins = ["hermes-lcm"];
      settings.context.engine = "lcm";
    };
  };
}
