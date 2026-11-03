{
  pkgs,
  desktop,
  t3Home,
}: let
  t3code = pkgs.symlinkJoin {
    inherit (pkgs.t3code) pname version meta;
    paths = [pkgs.t3code];
    nativeBuildInputs = [pkgs.makeBinaryWrapper];
    postBuild = ''
      for program in "$out/bin/"* "$out/Applications/"*.app/Contents/MacOS/*; do
        if [ ! -f "$program" ]; then
          continue
        fi

        wrapProgram "$program" \
          --set T3CODE_TELEMETRY_ENABLED false \
          --set T3CODE_HOME ${pkgs.lib.escapeShellArg t3Home}
      done
    '';
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
