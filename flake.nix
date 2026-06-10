{
  description = "Nix-based dotfiles for multiple machines";

  inputs = {
    # Bacon and bacon-ls for Rust development in neovim
    bacon = {
      url = "github:Canop/bacon";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # https://github.com/crisidev/bacon-ls/pull/101
    bacon-ls = {
      url = "github:iainlane/bacon-ls/22ab710c6bf76602272b5dc6e0c17fdd169dc1a0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.naersk.inputs.nixpkgs.follows = "nixpkgs";
    };

    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin-stable = {
      url = "github:catppuccin/nix/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };

    # Per-app theme repos consumed directly so the corresponding
    # `catppuccin/nix` modules can read their themes without IFD. Upstream
    # builds each port's `catppuccin.sources.<port>` from a `fetchFromGitHub`
    # derivation, so the modules' `importTOML`/`importJSON` reads force a build
    # during evaluation. Pointing `catppuccin.sources.<port>` at these
    # native-fetched inputs instead keeps upstream's file-placement code but
    # reads from a path that exists at evaluation time.
    catppuccin-bottom = {
      url = "github:catppuccin/bottom";
      flake = false;
    };
    # Canonical Catppuccin palette JSON. Read directly via
    # `inputs.catppuccin-palette + "/palette.json"` so we don't have to
    # vendor or duplicate the colour data.
    catppuccin-palette = {
      url = "github:catppuccin/palette/v1.8.0";
      flake = false;
    };

    claude-managed-settings = {
      url = "git+https://github.com/iainlane/claude-managed-settings?ref=iainlane/nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

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

    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.6.5";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hermes-lcm = {
      url = "github:stephenschoettler/hermes-lcm/v0.16.1";
      flake = false;
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

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nh = {
      url = "github:nix-community/nh";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pre-built nix-index database for faster `nix-locate` queries
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-system-graphics = {
      url = "github:soupglasses/nix-system-graphics";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixos-stable.follows = "nixpkgs-stable";
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

    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
