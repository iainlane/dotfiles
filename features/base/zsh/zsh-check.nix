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
  homeScript = text:
    pkgs.writeText "zsh-completion-init" (lib.replaceStrings [homeConfig.xdg.cacheHome] ["$HOME/.cache"] text);
  completionInit = homeScript homeConfig.programs.zsh.completionInit;
  activation = homeScript homeConfig.home.activation.zshCompletionDump.data;
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
  cacheProbe = pkgs.writeText "completion-cache-probe.zsh" ''
    setopt ERR_EXIT NO_UNSET

    expected="$HOME/.cache/zsh/$ZSH_VERSION/.zcompdump"
    mkdir -p "$HOME/.cache/zsh/other-version"
    print -r -- sentinel > "$HOME/.cache/zsh/other-version/.zcompdump"

    export DRY_RUN_CMD=
    bash ${activation}
    [[ -s $expected && -s $expected.zwc ]]

    source ${completionInit}
    [[ $_comp_dumpfile == $expected && -n $_comps[git] ]]
    [[ $(<"$HOME/.cache/zsh/other-version/.zcompdump") == sentinel ]]
  '';
in
  {
    "zsh-completion-cache-${hostConfig.name}" =
      pkgs.runCommandLocal "zsh-completion-cache-${hostConfig.name}" {
        nativeBuildInputs = [zsh];
      } ''
        export HOME="$TMPDIR/home"
        export ZDOTDIR="$HOME"
        mkdir -p "$HOME"
        zsh -f ${cacheProbe}
        touch "$out"
      '';
  }
  // lib.optionalAttrs (lib.elem hostConfig.os ["darwin" "nixos"]) {
    "zsh-global-completion-${hostConfig.name}" =
      pkgs.runCommandLocal "zsh-global-completion-${hostConfig.name}" {
        nativeBuildInputs = [zsh];
      } ''
        test ${lib.boolToString globalPolicy} = true
        zsh -f ${globalProbe}
        touch "$out"
      '';
  }
