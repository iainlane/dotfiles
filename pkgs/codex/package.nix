{
  bubblewrap,
  codex,
  lib,
  makeWrapper,
  ripgrep,
  stdenvNoCC,
}: let
  manifest = builtins.toJSON {
    layoutVersion = 1;
    # Build metadata makes the daemon treat this as a local build, which it
    # pins instead of replacing with upstream releases from its updater.
    version = "${codex.version}+nix";
    target = stdenvNoCC.hostPlatform.rust.rustcTarget;
    entrypoint = "bin/codex";
  };
in
  if !stdenvNoCC.hostPlatform.isLinux
  then codex
  else
    stdenvNoCC.mkDerivation {
      pname = "codex";
      inherit (codex) version meta passthru;

      nativeBuildInputs = [makeWrapper];

      dontUnpack = true;
      dontStrip = true;
      dontPatchELF = true;

      installPhase = ''
        runHook preInstall

        package=$out/libexec/codex
        mkdir -p $package/codex-resources $package/codex-path
        cp -r ${codex}/libexec/codex/bin $package/
        chmod -R u+w $package/bin
        cp ${lib.getExe bubblewrap} $package/codex-resources/bwrap
        cp ${lib.getExe ripgrep} $package/codex-path/rg
        echo '${manifest}' > $package/codex-package.json

        makeWrapper $package/bin/codex $out/bin/codex \
          --prefix PATH : ${lib.makeBinPath [bubblewrap]}
        ln -s ../libexec/codex/bin/codex-code-mode-host $out/bin/codex-code-mode-host
        ln -s ../libexec/codex/bin/logs_client $out/bin/logs_client
        cp -r ${codex}/share $out/

        runHook postInstall
      '';
    }
