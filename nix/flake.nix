{
  description = "Nix-based dotfiles for multiple machines";

  inputs = {
    # Bacon and bacon-ls for Rust development in neovim
    bacon.url = "github:Canop/bacon";
    # https://github.com/crisidev/bacon-ls/pull/101
    bacon-ls.url = "github:iainlane/bacon-ls/22ab710c6bf76602272b5dc6e0c17fdd169dc1a0";

    catppuccin.url = "github:catppuccin/nix";
    catppuccin-stable.url = "github:catppuccin/nix/release-25.11";

    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };

    deploy-rs.url = "github:serokell/deploy-rs";

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix.url = "github:nix-community/fenix";

    flake-parts.url = "github:hercules-ci/flake-parts";

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-stable = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    just-sublime = {
      url = "github:nk9/just_sublime";
      flake = false;
    };

    kolide-launcher = {
      url = "github:kolide/nix-agent/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:iainlane/lanzaboote/measured-boot";
      inputs.nixpkgs.follows = "nixpkgs-measured-boot";
    };

    llm-agents.url = "github:numtide/llm-agents.nix";

    mcp-servers-nix.url = "github:natsukium/mcp-servers-nix";

    nh.url = "github:nix-community/nh";

    nix-darwin.url = "github:LnL7/nix-darwin";

    # Pre-built nix-index database for faster `nix-locate` queries
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-system-graphics.url = "github:soupglasses/nix-system-graphics";

    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware";

    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixpkgs-measured-boot.url = "github:iainlane/nixpkgs/measured-boot";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";

    secrets = {
      url = "git+ssh://git@github.com/iainlane/dotfiles-secrets";
      flake = false;
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
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
      ];
    };
}
