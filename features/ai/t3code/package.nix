{
  pkgs,
  desktop,
}: let
  t3code = pkgs.t3code.override {
    t3code-unwrapped = pkgs.t3code.unwrapped.overrideAttrs (previous: {
      postFixup =
        (previous.postFixup or "")
        + ''
          for program in t3 t3code-desktop; do
            wrapProgram "$out/bin/$program" --set T3CODE_TELEMETRY_ENABLED false
          done
        '';
    });
  };
in
  if desktop
  then t3code
  else
    pkgs.runCommand "${t3code.name}-cli" {
      meta = t3code.meta // {mainProgram = "t3";};
    } ''
      mkdir -p "$out/bin" "$out/share"
      ln -s ${t3code}/bin/t3 "$out/bin/t3"
      for directory in bash-completion fish zsh; do
        if test -d "${t3code}/share/$directory"; then
          ln -s "${t3code}/share/$directory" "$out/share/$directory"
        fi
      done
    ''
