{
  pkgs-unstable,
  inputs,
  system,
}: {
  # Every language server Nix installs for Neovim, keyed by nixpkgs attribute
  # name. `features/base/neovim/home-manager.nix` puts each package in
  # `programs.neovim.extraPackages` and writes two lists to a JSON file that
  # `nvim/lua/plugins/nix-managed-mason.lua` reads:
  #
  # - `lsp_servers`: server names lspconfig is given with `mason = false`
  # - `mason_packages`: names dropped from Mason's `ensure_installed`
  #
  # The value describes how the server name and the Mason package name
  # differ from the nixpkgs name:
  #
  # - `null`: neither differs.
  #
  #   ```nix
  #   "pyright" = null;
  #   ```
  #
  # - a string: the server name. The Mason package name does not differ.
  #
  #   ```nix
  #   "lua-language-server" = "lua_ls";
  #   ```
  #
  # - an attribute set with `lsp`, `masonPackages` or both, each a name or a
  #   list of names. A field left out means that name is the nixpkgs attribute
  #   name.
  #
  #   ```nix
  #   "vscode-langservers-extracted" = {
  #     lsp = [ "cssls" "eslint" "jsonls" ];
  #     masonPackages = [ "css-lsp" "eslint-lsp" "json-lsp" ];
  #   };
  #   ```
  #
  # Write `masonPackages = []` when Mason has no package of that name.
  #
  # An attribute set may also have a `pkg`, the package itself, for a package
  # the host's primary nixpkgs channel does not have.
  "ansible-language-server" = {
    lsp = "ansiblels";
    pkg = pkgs-unstable.ansible-language-server;
  };
  # `bacon-ls` is selected as the Rust diagnostics provider via
  # `lazyvim_rust_diagnostics` in `nvim/lua/config/options.lua`. LazyVim's rust
  # extra registers `bacon_ls` with lspconfig when that flag is set; we need
  # the LSP server name here so `nix-managed-mason.lua` can disable Mason for
  # it. The runner binary `bacon` itself lives in `tools.nix`.
  "bacon-ls" = {
    lsp = "bacon_ls";
    pkg = inputs.bacon-ls.defaultPackage.${system};
  };
  "bash-language-server" = "bashls";
  # Biome is also the `biome-check` formatter that LazyVim's biome extra
  # gives conform. An entry in `tools.nix` only removes it from Mason's tool
  # list; Mason would still install its own copy for the language server, so
  # the entry is here.
  "biome" = null;
  # C/C++/Objective-C.
  "clang-tools" = {
    lsp = "clangd";
    masonPackages = "clangd";
  };
  "copilot-language-server" = "copilot";
  "deno" = "denols";
  "docker-compose-language-service" = "docker_compose_language_service";
  "dockerfile-language-server" = "dockerls";
  # Emmet abbreviation expansion (HTML/CSS and related templates).
  "emmet-language-server" = "emmet_language_server";
  "gopls" = null;
  "helm-ls" = "helm_ls";
  "jsonnet-language-server" = "jsonnet_ls";
  "just-lsp" = "just";
  "lua-language-server" = "lua_ls";
  # Markdown.
  "marksman" = null;
  "nixd" = {
    masonPackages = [];
  };
  "prisma-language-server" = "prismals";
  "pyright" = null;
  # Rego (Open Policy Agent).
  "regols" = null;
  # Python.
  "ruff" = null;
  "rust-analyzer" = "rust_analyzer";
  "svelte-language-server" = "svelte";
  "tailwindcss-language-server" = "tailwindcss";
  # TOML.
  "taplo" = null;
  "terraform-ls" = "terraformls";
  "typescript-language-server" = "ts_ls";
  # Multi-server package from VS Code.
  "vscode-langservers-extracted" = {
    lsp = [
      "cssls"
      "eslint"
      "jsonls"
    ];
    masonPackages = [
      "css-lsp"
      "eslint-lsp"
      "json-lsp"
    ];
  };
  # TypeScript/JavaScript via vtsls.
  "vtsls" = null;
  "wgsl-analyzer" = {
    lsp = "wgsl_analyzer";
    masonPackages = [];
  };
  "yaml-language-server" = "yamlls";
}
