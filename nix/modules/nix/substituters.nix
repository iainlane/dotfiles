# Support binary caches for the flakes we use.
{lib, ...}: let
  substituters = [
    "https://anyrun.cachix.org"
    "https://cache.nixos.org"
    "https://cache.numtide.com"
    "https://crane.cachix.org"
    "https://deploy-rs.cachix.org"
    "https://devenv.cachix.org"
    "https://hyprland.cachix.org"
    "https://neovim-nightly.cachix.org"
    "https://nix-community.cachix.org"
    "https://nix-gaming.cachix.org"
    "https://nix-on-droid.cachix.org"
    "https://nixpkgs-wayland.cachix.org"
    "https://numtide.cachix.org"
  ];

  trusted-public-keys = [
    "anyrun.cachix.org-1:pqBobmOjI7nKlsUMV25u9QHa9btJK65/C8vnO3p346s="
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "crane.cachix.org-1:8Scfpmn9w+hGdXH/Q9tTLiYAE/2dnJYRJP7kl80GuRk="
    "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    "deploy-rs.cachix.org-1:M+ZN++7fdqZFeIsvJyqeQrgnAbgsPNuv8z93uAJO43w="
    "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
    "neovim-nightly.cachix.org-1:fLrV5fy41LFKwyLAxJ0H13o6FOVGc4k6gXB5Y1dqtWw="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4="
    "nix-on-droid.cachix.org-1:56snoMJTXmDRC1Ei24CmKoUqvHJ9XCp+nidK7qkMQrU="
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    "nixpkgs-wayland.cachix.org-1:3lwxaILxMRkVhehr5StQprHdEo4IrE8sRho9R9HOLYA="
    "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
  ];

  trusted-users = ["@sudo"];
in {
  config = {
    # On Darwin, we write `nix.custom.conf` directly since `nix-darwin` doesn't
    # support `nix.settings.substituters` yet.
    _module.args.substitutersCustomConf = ''
      substituters = ${lib.concatStringsSep " " substituters}
      trusted-public-keys = ${lib.concatStringsSep " " trusted-public-keys}
    '';

    # On Linux we can use nix.settings via system-manager. Normally this would
    # update `/etc/nix/nix.conf`, but on Determinate Nix this is owned by the
    # system itself, so a few lines below here we redirect this to
    # `/etc/nix/nix.custom.conf`.
    nix.settings = {
      inherit substituters;
      inherit trusted-public-keys;
      inherit trusted-users;
    };
  };
}
