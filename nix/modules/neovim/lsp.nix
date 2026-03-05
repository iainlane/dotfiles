{
  # This file keeps Neovim's Nix-managed LSP mapping in one place. It lets us
  # install language tools via Nix. From this we generate a JSON file which we
  # load into Neovim to disable Mason installs for these tools.
  #
  # Map of Nix package name -> LSP/Mason metadata.
  #
  # This is normalised in `modules/neovim/default.nix` into:
  # - `lsp_servers`: server names that should be configured with `mason = false`
  # - `mason_packages`: Mason package names to exclude from Mason auto-installs
  #
  # Value formats:
  #
  # - `null`: both the LSP server name and Mason package name are the same as
  #    the Nix package name:
  #
  #   ```nix
  #   "pyright" = null;
  #   ```
  #
  # - `"lspName"`: the LSP server name is different from the Nix package name,
  #    but the Mason package name is the same as the Nix package name:
  #
  #   ```nix
  #   "lua-language-server" = "lua_ls";
  #   ```
  #
  # - `{ lsp = ...; masonPackages = ...; }`: fully custom form, for when both
  #   the LSP server name and Mason package name differ from the Nix package name:
  #
  #   ```nix
  #   "vscode-langservers-extracted" = {
  #     lsp = [ "cssls" "eslint" "jsonls" ];
  #     masonPackages = [ "css-lsp" "eslint-lsp" "json-lsp" ];
  #   };
  #   ```
  #
  # Set `masonPackages = []` when no Mason package exclusion is needed for that
  # entry (for example when there is no matching Mason package name).
  "ansible-language-server" = "ansiblels";
  "bash-language-server" = "bashls";
  # C/C++/Objective-C.
  "clang-tools" = {
    lsp = "clangd";
    masonPackages = "clangd";
  };
  "copilot-language-server" = "copilot";
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
