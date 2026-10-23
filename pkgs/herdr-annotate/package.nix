{
  bash,
  fetchFromGitHub,
  lib,
  makeWrapper,
  plannotator-tui,
  rustPlatform,
  stdenv,
  wl-clipboard,
  xclip,
  xsel,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "herdr-annotate";
  version = "0.9.1-unstable-2026-10-15";

  src = fetchFromGitHub {
    owner = "plannotator";
    repo = "herdr-annotate";
    rev = "c5e565e9bdbb52d152ad15169f38ed8bae31b610";
    hash = "sha256-qh6vQ4e4ehIuY8bIV6H0uScO6AQySCLDYwHkI24csFQ=";
  };

  cargoRoot = "rust";
  buildAndTestSubdir = finalAttrs.cargoRoot;
  cargoHash = "sha256-ReKL4pHo6doBn4XBOr0WbEyrEnoDbnz/wo56QEwYqOg=";

  nativeBuildInputs = [makeWrapper];

  postPatch = ''
    substituteInPlace rust/tests/commands.rs \
      --replace-fail '#!/bin/sh' '#!${lib.getExe bash}'
  '';

  postInstall = ''
    pluginRoot="$out/share/herdr/plugins/herdr-annotate"
    mkdir -p "$pluginRoot/bin"
    sed '/^\[\[build\]\]/,/^$/d' herdr-plugin.toml > "$pluginRoot/herdr-plugin.toml"
    install -Dm644 LICENSE README.md -t "$pluginRoot"

    substituteInPlace "$pluginRoot/herdr-plugin.toml" \
      --replace-fail 'command = ["sh", "-c", "exec bash \"$HERDR_PLUGIN_ROOT/scripts/plannotator-tui.sh\" herdr pane"]' \
        'command = ["${lib.getExe plannotator-tui}", "herdr", "pane"]'

    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      wrapProgram "$out/bin/herdr-annotate" \
        --prefix PATH : ${lib.makeBinPath [wl-clipboard xclip xsel]}
    ''}

    ln -s "$out/bin/herdr-annotate" "$pluginRoot/bin/herdr-annotate.exe"
    ln -s ${lib.getExe plannotator-tui} "$pluginRoot/bin/plannotator-tui.exe"
  '';

  passthru = {
    pluginRoot = "${finalAttrs.finalPackage}/share/herdr/plugins/herdr-annotate";
    updateScript = null;
  };

  meta = {
    description = "Herdr plugin for annotating terminal output, Markdown and agent replies";
    homepage = "https://github.com/plannotator/herdr-annotate";
    license = lib.licenses.mit;
    mainProgram = "herdr-annotate";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
