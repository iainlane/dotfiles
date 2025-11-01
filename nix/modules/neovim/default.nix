{
  pkgs,
  config,
  inputs,
  system,
  ...
}: {
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    package = inputs.neovim-nightly.packages.${system}.neovim;

    extraPackages = with pkgs; [
      go
      lua5_1
      luarocks
      nixd
      nodejs
    ];
  };

  xdg = {
    configFile."nvim".source = ./nvim;
    stateFile."nvim/lazy-lock.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dev/random/dotfiles/nix/modules/neovim/nvim/lazy-lock.json";
  };
}
