{
  lib,
  pkgs,
  pkgs-unstable,
  config,
  flakePath,
  inputs,
  system,
  ...
}: let
  lspSpec = import ./lsp.nix {
    inherit pkgs-unstable inputs system;
  };
  toolsSpec = import ./tools.nix {
    inherit pkgs;
  };

  normaliseLspEntry = packageName: spec: let
    entry =
      if spec == null
      then {}
      else if builtins.isString spec
      then {lsp = spec;}
      else spec;
  in {
    inherit packageName;
    pkg = entry.pkg or pkgs.${packageName};
    lspServers = lib.toList (entry.lsp or packageName);
    masonPackages =
      if entry ? masonPackages
      then lib.toList entry.masonPackages
      else [packageName];
  };

  lspEntries = lib.mapAttrsToList normaliseLspEntry lspSpec;

  nixManagedLspJson = (pkgs.formats.json {}).generate "nix-managed-lsp.json" {
    lsp_servers = lib.unique (lib.concatMap (entry: entry.lspServers) lspEntries);
    mason_packages = lib.unique (
      lib.concatMap (entry: entry.masonPackages) lspEntries
      ++ builtins.attrNames toolsSpec
    );
  };
in {
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    package = pkgs-unstable.neovim-unwrapped;

    extraPackages = lib.unique (
      (with pkgs; [
        clang
        go-jsonnet
        gnumake
        lua5_1
        luarocks
        nodejs
        tree-sitter
      ])
      ++ map (entry: entry.pkg) lspEntries
      ++ builtins.attrValues toolsSpec
    );

    withPython3 = false;
    withRuby = false;
  };

  xdg = {
    configFile."nvim".source = ../../../nvim;

    # LazyVim's Svelte extra hardcodes the location it loads the Svelte language
    # server from. Here we symlink to our Nix-managed installation from that
    # location.
    dataFile."nvim/mason/packages/svelte-language-server/node_modules/typescript-svelte-plugin".source = "${pkgs.svelte-language-server}/lib/node_modules/svelte-language-server/packages/typescript-plugin";

    stateFile = {
      "nvim/lazy-lock.json".source =
        config.lib.file.mkOutOfStoreSymlink "${flakePath}/nvim/lazy-lock.json";
      "nvim/nix-managed-lsp.json".source = nixManagedLspJson;
    };
  };
}
