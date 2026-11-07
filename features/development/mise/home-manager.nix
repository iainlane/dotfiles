{
  config,
  lib,
  pkgs-unstable,
  ...
}: {
  programs.mise = {
    enable = true;
    package = pkgs-unstable.mise;
    enableZshIntegration = true;

    globalConfig = {
      tools = {
        go = "latest";
        node = "lts";
        python = "latest";
      };

      settings = {
        idiomatic_version_file_enable_tools = ["go" "node" "python"];
        not_found_auto_install = true;
        tool_update.global_auto = true;
      };

      hooks.cd = "${lib.getExe config.programs.mise.package} install --quiet";
    };
  };
}
