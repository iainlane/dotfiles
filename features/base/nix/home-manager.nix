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

  # Ensure standalone nix commands (e.g. `nix shell`) see the same nixpkgs
  # config as our flakes, so we can use unfree packages. The `pkgs.config`
  # object contains functions and their metadata which can't be
  # serialised, so we filter those out.
  xdg.configFile."nixpkgs/config.nix".text = let
    isPlainValue = v:
      !builtins.isFunction v
      && !(builtins.isAttrs v && v ? __functionArgs);
  in
    lib.generators.toPretty {} (lib.filterAttrsRecursive (_: isPlainValue) pkgs.config);
}
