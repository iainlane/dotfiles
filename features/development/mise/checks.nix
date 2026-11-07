{
  homeConfig,
  hostConfig,
  ...
}: {pkgs, ...}: let
  inherit (pkgs) lib;
  mise = homeConfig.programs.mise;
  expected = {
    tools = {
      go = "latest";
      node = "lts";
      python = "latest";
    };
    autoUpdate = true;
    aggressive = false;
  };
  actual = {
    tools = mise.globalConfig.tools or {};
    autoUpdate = mise.globalConfig.settings.tool_update.global_auto or false;
    aggressive = mise.globalConfig.settings.activate_aggressive or false;
  };
in {
  "mise-policy-${hostConfig.name}" = pkgs.runCommandLocal "mise-policy-${hostConfig.name}" {} ''
    diff -u ${pkgs.writeText "mise-expected.json" (builtins.toJSON expected)} \
      ${pkgs.writeText "mise-actual.json" (builtins.toJSON actual)}
    touch "$out"
  '';

  "mise-activation-${hostConfig.name}" =
    pkgs.runCommandLocal "mise-activation-${hostConfig.name}" {
      nativeBuildInputs = [mise.package pkgs.zsh pkgs.bash pkgs.coreutils pkgs.direnv pkgs.git];
    } ''
      substitute ${./mise.test.zsh} mise.test.zsh \
        --replace-fail '/usr/bin/env bash' '${lib.getExe pkgs.bash}'
      ln -s ${homeConfig.xdg.configFile."mise/config.toml".source} "$TMPDIR/global.toml"
      env -i HOME="$TMPDIR/home" PATH="$PATH" \
        MISE_GLOBAL_CONFIG_FILE="$TMPDIR/global.toml" \
        MISE_TEST_MISE=${lib.getExe mise.package} \
        MISE_TEST_DIRENV=${lib.getExe pkgs.direnv} \
        zsh -fi "$PWD/mise.test.zsh"
      touch "$out"
    '';
}
