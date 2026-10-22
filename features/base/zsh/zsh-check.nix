{
  homeConfig,
  systemConfig,
  hostConfig,
}: {pkgs, ...}: let
  inherit (pkgs) lib;
  zsh = homeConfig.programs.zsh.package;
  globalInit = builtins.readFile ./global-compinit.zsh;
  globalPolicy =
    !systemConfig.programs.zsh.enableGlobalCompInit
    && lib.hasInfix globalInit systemConfig.programs.zsh.interactiveShellInit;
  globalProbe = pkgs.writeText "global-compinit-probe.zsh" ''
    setopt ERR_EXIT NO_UNSET

    for mode in unset empty managed; do
      (
        unset skip_global_compinit
        [[ $mode != empty ]] || skip_global_compinit=
        [[ $mode != managed ]] || skip_global_compinit=1

        calls=0
        autoload() { :; }
        compinit() { (( ++calls )); }
        source ${./global-compinit.zsh}

        expected=1
        [[ $mode != managed ]] || expected=0
        [[ $calls == $expected ]]
      )
    done
  '';
in
  lib.optionalAttrs (lib.elem hostConfig.os ["darwin" "nixos"]) {
    "zsh-global-completion-${hostConfig.name}" =
      pkgs.runCommandLocal "zsh-global-completion-${hostConfig.name}" {
        nativeBuildInputs = [zsh];
      } ''
        test ${lib.boolToString globalPolicy} = true
        zsh -f ${globalProbe}
        touch "$out"
      '';
  }
