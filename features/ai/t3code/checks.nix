{pkgs, ...}: let
  probe = pkgs.writeShellScript "t3code-environment-probe" ''
    printf '%s\n' "''${T3CODE_TELEMETRY_ENABLED-unset}" "$@"
  '';
  fixture = pkgs.stdenvNoCC.mkDerivation {
    pname = "t3code-fixture";
    inherit (pkgs.t3code) version meta;
    dontUnpack = true;
    nativeBuildInputs = [pkgs.makeBinaryWrapper];
    installPhase = ''
      mkdir -p "$out/bin" "$out/share/applications" "$out/share/zsh/site-functions"
      makeWrapper ${probe} "$out/bin/t3"
      makeWrapper ${probe} "$out/bin/t3code-desktop"
      mkdir -p "$out/Applications/T3 Code (Alpha).app/Contents/MacOS"
      makeWrapper "$out/bin/t3code-desktop" \
        "$out/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)"
      touch "$out/share/applications/t3code.desktop"
      touch "$out/share/zsh/site-functions/_t3"
    '';
  };
  fixturePackage = pkgs.t3code.override {
    t3code-unwrapped = fixture;
    enableCodex = false;
    enableGitHub = false;
    enableGit = false;
    enableResourceMonitor = false;
  };
  configured = desktop:
    import ./package.nix {
      pkgs = pkgs // {t3code = fixturePackage;};
      inherit desktop;
    };
  cli = configured false;
  desktop = configured true;
in {
  t3code-environment = pkgs.runCommand "t3code-environment" {} ''
    printf '%s\n' false 'argument with spaces' --flag > expected
    for program in \
      ${cli}/bin/t3 \
      ${desktop}/bin/t3 \
      ${desktop}/bin/t3code-desktop \
      "${desktop}/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)"; do
      env -u T3CODE_TELEMETRY_ENABLED "$program" 'argument with spaces' --flag > actual
      diff -u expected actual
      T3CODE_TELEMETRY_ENABLED=true "$program" 'argument with spaces' --flag > actual
      diff -u expected actual
    done

    test ! -e ${cli}/bin/t3code-desktop
    test ! -e ${cli}/Applications
    test ! -e ${cli}/share/applications
    test -e ${cli}/share/zsh/site-functions/_t3
    test -e ${desktop}/share/applications/t3code.desktop
    touch "$out"
  '';
}
