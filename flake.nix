{
  description = "Nix-based dotfiles for multiple machines";

  inputs = {
    # bacon-ls for Rust development in neovim
    bacon-ls = {
      url = "github:crisidev/bacon-ls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.naersk.inputs.nixpkgs.follows = "nixpkgs";
    };

    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin-stable = {
      url = "github:catppuccin/nix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # The bat theme repository, read by `programs.bat.themes` in
    # features/base/cli-tools/home-manager.nix. bat is themed through Home
    # Manager's own bat module, not through `catppuccin/nix`.
    catppuccin-bat = {
      url = "github:catppuccin/bat";
      flake = false;
    };
    # The bottom theme repository. features/base/catppuccin/home-manager.nix
    # sets `catppuccin.sources.bottom` to this input's `themes` directory.
    # Upstream builds each port's `catppuccin.sources.<port>` with
    # `fetchFromGitHub`, so the Home Manager module's `importTOML` and
    # `importJSON` reads of that source force a build during evaluation. This
    # input is fetched natively and its path exists at evaluation time, so the
    # same reads need no import from derivation.
    catppuccin-bottom = {
      url = "github:catppuccin/bottom";
      flake = false;
    };
    # Canonical Catppuccin palette JSON. Read directly via
    # `inputs.catppuccin-palette + "/palette.json"`, keeping upstream as the
    # single source of the colour data.
    catppuccin-palette = {
      url = "github:catppuccin/palette/v1.8.0";
      flake = false;
    };

    cupboard.url = "https://flakehub.com/f/underwhelmingperformance/cupboard/0.0";

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

    # Agent skill shipped in the `gh-stack` repository's `skills/gh-stack/`.
    # The shared skills set (`features/ai/skills.nix`) reads it from this
    # native-fetched input, so the skill directory exists at evaluation time
    # on every platform. Pinned to a release tag; bumped by
    # `nix run .#update-gh-stack-skill`.
    gh-stack-skill = {
      url = "github:github/gh-stack/v0.1.0";
      flake = false;
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
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.9.14";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The v1.0.0-rc.1 tag plus the three commits of
    # stephenschoettler/hermes-lcm#551, on the fork's
    # `openai-embeddings-on-v1.0.0-rc.1` branch. #551 adds an
    # OpenAI-compatible embedding provider, which ancaster uses to send
    # embedding requests to OpenRouter with the API key that Hermes already
    # has for its models. None of upstream's three providers suits ancaster:
    # Voyage would need a second account, Ollama would need another service
    # on the Pi, and nixpkgs lists aarch64-linux in fastembed's
    # `badPlatforms`. When #551 merges, restore the release tag and add
    # hermes-lcm to `flakeInputs` in flake/parts/updaters.nix so it follows
    # releases again.
    hermes-lcm = {
      url = "github:iainlane/hermes-lcm/34444ff9ba99a79f791044156fa9641c46210e9e";
      flake = false;
    };

    just-sublime = {
      url = "github:nk9/just_sublime";
      flake = false;
    };

    kolide-launcher = {
      url = "github:kolide/nix-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `measured-boot` is our branch of lanzaboote. It adds support for
    # predicting the boot components' TPM2 measurements, generating a
    # systemd-pcrlock policy from them, and enrolling that policy into the LUKS
    # volumes. This is what lets bonington unlock its disk without a
    # passphrase. Upstream is taking the work in pieces, most recently
    # nix-community/lanzaboote#637. The branch needs the two NixOS commits on
    # `nixpkgs-measured-boot` below, so the two pins move together. Drop both
    # once a lanzaboote release includes measured boot.
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

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-direnv = {
      url = "github:nix-community/nix-direnv/8c7ebb294d997bc1720ddf3f7ee9ed27c290a0e6";
      flake = false;
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

    # nixpkgs-unstable with two commits that the lanzaboote branch above needs: the
    # pcrlock service units and options on the tpm2 module, and the tmpfiles
    # rules for the PCR credentials deposited by the stub. Only lanzaboote
    # evaluates against it. Drop it with the lanzaboote pin.
    nixpkgs-measured-boot.url = "github:iainlane/nixpkgs/measured-boot";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-26.05";

    # Declarative Podman quadlets. Home Manager's `services.podman` only ever
    # writes user units, so rootful containers need this instead.
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";

    secrets = {
      url = "git+ssh://git@github.com/iainlane/dotfiles-secrets";
      flake = false;
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Our branch of starship, with starship/starship#6834 applied. The patch
    # adds zsh glitch sequences so the shell accounts for wide characters when
    # positioning the cursor after the prompt. Drop this input when the pull
    # request merges and reaches a release.
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
