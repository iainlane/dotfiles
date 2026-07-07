# Temporary fix for a broken source hash in ctranslate2 4.8.1.
#
# The nixpkgs-unstable bump `ctranslate2: 4.8.0 -> 4.8.1` (NixOS/nixpkgs
# 7d4a269) recorded the wrong `src` hash, so the fixed-output fetch fails:
#
#   hash mismatch in fixed-output derivation:
#     specified: sha256-+82u+w08wGX0oh1wBaH/epI2IH7lxbvMThJEoGt0Kvk=
#     got:       sha256-cchwv+esysn/0v6RqD5zp306HfzOjjlCxH5usLETXs0=
#
# This blocks `open-webui` (via `faster-whisper`) on the hosts that track the
# unstable channel. It is fixed upstream by NixOS/nixpkgs a4c0db7
# ("ctranslate2: fix src hash"), which is on master but has not yet reached the
# `nixpkgs-unstable` channel we pin. Until it does, correct the hash ourselves.
#
# Removability is decided from the unstable input directly, so the guard below
# fires no matter which package set the overlay is applied to: once the channel
# ships a ctranslate2 4.8.1 whose recorded hash is no longer the broken one,
# evaluating `ctranslate2` throws and CI fails loudly, prompting removal.
{inputs}: _final: prev: let
  inherit (prev.stdenv.hostPlatform) system;

  brokenHash = "sha256-+82u+w08wGX0oh1wBaH/epI2IH7lxbvMThJEoGt0Kvk=";
  correctHash = "sha256-cchwv+esysn/0v6RqD5zp306HfzOjjlCxH5usLETXs0=";

  upstream = inputs.nixpkgs.legacyPackages.${system}.ctranslate2;

  channelStillBroken = upstream.version == "4.8.1" && upstream.src.outputHash == brokenHash;
in {
  ctranslate2 =
    if prev.ctranslate2.version != "4.8.1"
    then prev.ctranslate2
    else if channelStillBroken
    then
      prev.ctranslate2.overrideAttrs (old: {
        src = old.src.overrideAttrs (_: {
          outputHash = correctHash;
        });
      })
    else
      throw ''
        overlays/ctranslate2.nix is redundant: the nixpkgs-unstable channel no
        longer ships ctranslate2 4.8.1 with the broken source hash (fixed
        upstream by NixOS/nixpkgs a4c0db7). Delete overlays/ctranslate2.nix.
      '';
}
