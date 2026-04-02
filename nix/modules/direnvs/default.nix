{lib, ...}: {
  options.flake.direnvPackages = lib.mkOption {
    type = lib.types.attrsOf lib.types.unspecified;
    default = {};
    description = "Language package sets for direnv shells. Each value is a function pkgs -> [packages].";
  };

  config.flake.direnvPackages = {
    go = pkgs:
      with pkgs; [
        go
        gopls
        gotools
        golangci-lint
        delve
      ];

    rust = pkgs: let
      inherit (pkgs) fenix;
      stableToolchain = fenix.stable.withComponents [
        "cargo"
        "clippy"
        "rust-src"
        "rustc"
        "rustfmt"
      ];
      nightlyRustfmt = fenix.complete.withComponents ["rustfmt"];
    in [
      stableToolchain
      nightlyRustfmt
      fenix.rust-analyzer
    ];

    python = pkgs:
      with pkgs; [
        python3
        ruff
        pyright
      ];

    typescript = pkgs:
      with pkgs; [
        corepack
        nodejs
        pnpm
        typescript
        pkgs."typescript-language-server"
      ];

    lua = pkgs:
      with pkgs; [
        lua
        luarocks
        lua-language-server
      ];
  };
}
