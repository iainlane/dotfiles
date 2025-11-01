{
  description = "Nix-based dotfiles for multiple machines";

  # Flake inputs define the external dependencies for this configuration.
  # Most use `inputs.nixpkgs.follows = "nixpkgs"` to ensure all packages come
  # from the same nixpkgs revision, avoiding version mismatches.
  inputs = {
    # The package universe. nixpkgs-unstable gets updates continuously;
    # nixpkgs-stable is for packages that need a known-stable version.
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";

    # Colour scheme applied consistently across terminal, editor, etc.
    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # bat syntax highlighting themes (non-flake, just the theme files)
    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Sublime Text syntax for justfiles (non-flake, used by bat)
    just-sublime = {
      url = "github:nk9/just_sublime";
      flake = false;
    };

    # Remote deployment tool with automatic rollback on failure
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Modular flake structure - lets us split flake.nix across multiple files
    flake-parts.url = "github:hercules-ci/flake-parts";

    # Rust toolchain manager - provides nightly Rust and cross-compilation
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Manages dotfiles and user packages declaratively
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative MCP server configuration for AI tools (see modules/ai/)
    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    neovim-nightly = {
      url = "github:nix-community/neovim-nightly-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # macOS system configuration (similar to NixOS modules but for Darwin)
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Unified code formatter configuration
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixOS-style config for non-NixOS Linux (see os/linux/)
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Mesa/graphics drivers for non-NixOS Linux systems
    nix-system-graphics = {
      url = "github:soupglasses/nix-system-graphics";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Custom starship with wide character support for zsh
    # https://github.com/starship/starship/pull/6834
    starship-custom = {
      url = "github:iainlane/starship/iainlane/feat-zsh-wide-char-support";
      flake = false;
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
        "x86_64-darwin"
      ];
    };
}
