{
  description = "Nix-based dotfiles for multiple machines";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:nixos/nixpkgs/master";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";

    catppuccin.url = "github:catppuccin/nix";

    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };

    deploy-rs.url = "github:serokell/deploy-rs";

    fenix.url = "github:nix-community/fenix";

    flake-parts.url = "github:hercules-ci/flake-parts";

    # Bacon and bacon-ls for Rust development in neovim
    bacon.url = "github:Canop/bacon";
    bacon-ls.url = "github:crisidev/bacon-ls";

    home-manager.url = "github:nix-community/home-manager";

    just-sublime = {
      url = "github:nk9/just_sublime";
      flake = false;
    };

    llm-agents.url = "github:numtide/llm-agents.nix";

    mcp-servers-nix.url = "github:natsukium/mcp-servers-nix";

    neovim-nightly.url = "github:nix-community/neovim-nightly-overlay";

    # nh v4.3.0-beta1 fixes path quoting bug with spaces in PATH
    # https://github.com/nix-community/nh/commit/4ae85ee
    nh.url = "github:nix-community/nh/v4.3.0-beta1";

    nix-darwin.url = "github:LnL7/nix-darwin";

    # Pre-built nix-index database for faster `nix-locate` queries
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-system-graphics.url = "github:soupglasses/nix-system-graphics";

    rustanka = {
      url = "github:grafana/rustanka";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Custom starship with wide character support for zsh
    # https://github.com/starship/starship/pull/6834
    starship-custom = {
      url = "github:iainlane/starship/iainlane/feat-zsh-wide-char-support";
      flake = false;
    };

    system-manager.url = "github:numtide/system-manager";

    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        ./flake/parts
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    };
}
