{
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

    # nix-index provides `nix-locate`, which reports which package contains a
    # given file. nix-index-database ships a prebuilt database, so nothing
    # builds an index on this machine.
    nix-index = {
      enable = true;
      # The command-not-found handler runs on every unrecognised command and
      # can be slow. comma, below, does the same lookup only when asked.
      enableZshIntegration = false;
    };

    # comma runs a program from nixpkgs without installing it: `, cowsay hello`.
    nix-index-database.comma.enable = true;
  };

  # Give impure evaluations of nixpkgs (`nix-shell`, `nix-env`, `<nixpkgs>`
  # in a repl) the same configuration as this flake, so they can build
  # unfree packages too. Flake commands such as `nix shell nixpkgs#hello`
  # never read this file. Both nixpkgs channels read it, and their option
  # types differ, so it contains only the settings that this flake chooses.
  xdg.configFile."nixpkgs/config.nix".text = lib.generators.toPretty {} (import ../../../lib/nixpkgs-config.nix);
}
