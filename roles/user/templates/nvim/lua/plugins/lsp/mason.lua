return {
  { "mason-org/mason.nvim" },
  { "mason-org/mason-lspconfig.nvim" },

  {
    "mason-org/mason.nvim",
    dependencies = {
      "WhoIsSethDaniel/mason-tool-installer.nvim",
    },

    opts = {
      ensure_installed = {
        "css-lsp",
        "emmet-language-server",
        "eslint-lsp",
        "gh-actions-language-server",
        "golangci-lint",
        "gopls",
        "htmlbeautifier",
        "jsonnet-language-server",
        "jsonnetfmt",
        "lua-language-server",
        "markdownlint",
        "prettierd",
        "prisma-language-server",
        "pyright",
        "rust-analyzer",
        "sorbet", -- ruby
        "svelte-language-server",
        "tailwindcss-language-server",
        "typescript-language-server",
      },
    },
  },
}
