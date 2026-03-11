let
  cacheDefinitions = [
    {
      domain = "anyrun.cachix.org";
      key = "pqBobmOjI7nKlsUMV25u9QHa9btJK65/C8vnO3p346s=";
    }
    {
      domain = "cache.nixos.org";
      key = "6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
    }
    {
      domain = "cache.numtide.com";
      publicKeyName = "niks3.numtide.com";
      key = "DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=";
    }
    {
      domain = "crane.cachix.org";
      key = "8Scfpmn9w+hGdXH/Q9tTLiYAE/2dnJYRJP7kl80GuRk=";
    }
    {
      domain = "deploy-rs.cachix.org";
      key = "xfNobmiwF/vzvK1gpfediPwpdIP0rpDV2rYqx40zdSI=";
    }
    {
      domain = "devenv.cachix.org";
      key = "w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    }
    {
      domain = "hyprland.cachix.org";
      key = "a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=";
    }
    {
      domain = "neovim-nightly.cachix.org";
      key = "fLrV5fy41LFKwyLAxJ0H13o6FOVGc4k6gXB5Y1dqtWw=";
    }
    {
      domain = "nix-community.cachix.org";
      key = "mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
    }
    {
      domain = "nix-gaming.cachix.org";
      key = "nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4=";
    }
    {
      domain = "nix-on-droid.cachix.org";
      key = "56snoMJTXmDRC1Ei24CmKoUqvHJ9XCp+nidK7qkMQrU=";
    }
    {
      domain = "nixpkgs-wayland.cachix.org";
      key = "3lwxaILxMRkVhehr5StQprHdEo4IrE8sRho9R9HOLYA=";
    }
    {
      domain = "numtide.cachix.org";
      key = "2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE=";
    }
  ];

  binaryCaches =
    map (cache:
      cache
      // {
        substituter = "https://${cache.domain}";
        publicKey = "${cache.publicKeyName or cache.domain}-1:${cache.key}";
      })
    cacheDefinitions;
in {
  inherit binaryCaches;

  substituters = map (cache: cache.substituter) binaryCaches;
  trusted-public-keys = map (cache: cache.publicKey) binaryCaches;

  trusted-users = [
    "root"
    "@sudo"
    "@admin"
  ];
}
