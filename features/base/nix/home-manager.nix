{
  pkgs,
  lib,
  inputs,
  flakePath,
  ...
}: {
  imports = [
    inputs.nix-index-database.homeModules.nix-index
  ];

  programs = {
    nh = {
      enable = true;
      flake = flakePath;
    };

    # nix-index provides `nix-locate` for finding which package provides a file.
    # The database is pre-built by nix-index-database, so no local indexing needed.
    nix-index = {
      enable = true;
      # The command-not-found handler can be slow; comma (`,`, below)
      # covers running packages without installing them.
      enableZshIntegration = false;
    };

    # Comma lets you run programs from nixpkgs without installing them:
    # `, cowsay hello` runs cowsay from nixpkgs
    nix-index-database.comma.enable = true;
  };

  # Give impure evaluations of nixpkgs (`nix-shell`, `nix-env`, `<nixpkgs>`
  # in a repl) the same configuration as our flakes, so they can build
  # unfree packages too. Flake commands such as `nix shell nixpkgs#hello`
  # never read this file. `pkgs.config` contains functions and their
  # metadata, which cannot be serialised, so they are filtered out.
  xdg.configFile."nixpkgs/config.nix".text = let
    isPlainValue = v:
      !builtins.isFunction v
      && !(builtins.isAttrs v && v ? __functionArgs);
  in
    lib.generators.toPretty {} (lib.filterAttrsRecursive (_: isPlainValue) pkgs.config);
}
