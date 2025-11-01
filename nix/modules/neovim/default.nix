{
  pkgs,
  config,
  inputs,
  system,
  ...
}: let
  lspSpec = import ./lsp.nix;
  toolsSpec = import ./tools.nix {
    inherit pkgs inputs system;
  };

  normaliseList = value:
    if builtins.isList value
    then value
    else [value];

  normaliseLspEntry = packageName: spec: let
    entry =
      if spec == null
      then {}
      else if builtins.isString spec
      then {lsp = spec;}
      else spec;
  in {
    inherit packageName;
    lspServers = normaliseList (
      entry.lsp or packageName
    );
    masonPackages =
      if entry ? masonPackages
      then normaliseList entry.masonPackages
      else [packageName];
  };

  lspEntries = map (packageName: normaliseLspEntry packageName lspSpec.${packageName}) (builtins.attrNames lspSpec);

  nixManagedLspJson = (pkgs.formats.json {}).generate "nix-managed-lsp.json" {
    lsp_servers = pkgs.lib.unique (builtins.concatLists (map (entry: entry.lspServers) lspEntries));
    mason_packages = pkgs.lib.unique (
      builtins.concatLists (map (entry: entry.masonPackages) lspEntries)
      ++ builtins.attrNames toolsSpec
    );
  };
in {
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    package = inputs.neovim-nightly.packages.${system}.neovim;

    extraPackages = pkgs.lib.unique (
      (with pkgs; [
        go-jsonnet
        gnumake
        lua5_1
        luarocks
        nodejs
        ruff
        tree-sitter
      ])
      ++ map (entry: builtins.getAttr entry.packageName pkgs) lspEntries
      ++ builtins.attrValues toolsSpec
    );
  };

  xdg = {
    configFile."nvim".source = ./nvim;

    # LazyVim's Svelte extra hardcodes the location it loads the Svelte language
    # server from. Here we symlink to our Nix-managed installation from that
    # location.
    dataFile."nvim/mason/packages/svelte-language-server/node_modules/typescript-svelte-plugin".source = "${pkgs.svelte-language-server}/lib/node_modules/svelte-language-server/packages/typescript-plugin";

    stateFile = {
      "nvim/lazy-lock.json".source =
        config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dev/random/dotfiles/nix/modules/neovim/nvim/lazy-lock.json";
      "nvim/nix-managed-lsp.json".source = nixManagedLspJson;
    };
  };
}
