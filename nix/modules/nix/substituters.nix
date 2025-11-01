{lib, ...}: let
  substituters = [
    "https://anyrun.cachix.org"
    "https://cache.nixos.org"
    "https://crane.cachix.org"
    "https://deploy-rs.cachix.org"
    "https://devenv.cachix.org"
    "https://fenix.cachix.org"
    "https://ghostty.cachix.org"
    "https://hyprland.cachix.org"
    "https://neovim-nightly.cachix.org"
    "https://nix-community.cachix.org"
    "https://nix-gaming.cachix.org"
    "https://nix-on-droid.cachix.org"
    "https://nix-system-graphics.cachix.org"
    "https://nixpkgs-wayland.cachix.org"
    "https://numtide.cachix.org"
  ];

  trusted-public-keys = [
    "anyrun.cachix.org-1:pqBobmACjI1nKNT5ocbcoFIFPOf7DrncW3RO7BRk2SE="
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPSQIYQoPDy9OM="
    "crane.cachix.org-1:8Scfpmn9w+hGdXH/Q9tTLiYAE/2dnJYRJP7k80zKn34="
    "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuib0v3MYw6qhrCXI3BPA2vcteY="
    "deploy-rs.cachix.org-1:0Nv93YrF2yl2sGd7xiK1Q4Q7UeT2iKQe0JZPf9x+DRk="
    "fenix.cachix.org-1:4Dn+j7Gxzjw1mGbz8cJ/7F4Aq6E8H9C+/qFj8+7+9E="
    "ghostty.cachix.org-1:QB389yOtDy1eun2+Jm4YHtYh64Vfo6iG5n5oyCuw7Gs="
    "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
    "neovim-nightly.cachix.org-1:1i1lnth9j8jbi2hvkbksa1r9dph19hryc1h3k7v3j0="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXa4/EhscD6tmXM4="
    "nix-on-droid.cachix.org-1:7bDp2w+3lW7UmsH1Z6/+6ONg0hCjz+Q8S+8W9x9c4g="
    "nix-system-graphics.cachix.org-1:7bDp2w+3lW7UmsH1Z6/+6ONg0hCjz+Q8S+8W9x9c4g="
    "nixpkgs-wayland.cachix.org-1:3lwxa3x1gjRzKx8/ZI6o0F2hWjHD0XHtXcSg442pg7g="
    "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0eXVWBceZp272UAo="
  ];
in {
  config = {
    # Export substituters and keys for use by manual config on nix-darwin
    _module.args.substitutersCustomConf = ''
      substituters = ${lib.concatStringsSep " " substituters}
      trusted-public-keys = ${lib.concatStringsSep " " trusted-public-keys}
    '';

    # Use nix.settings for system-manager (Linux) which properly supports it
    # This is ignored on nix-darwin where nix.enable = false
    nix.settings = {
      substituters = substituters;
      trusted-public-keys = trusted-public-keys;
    };
  };
}
