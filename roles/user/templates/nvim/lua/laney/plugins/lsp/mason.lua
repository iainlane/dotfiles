return {
  "williamboman/mason.nvim",
  dependencies = {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
  },

  opts = {
    ensure_installed = {
      "css-lsp",
      "emmet-language-server",
      "eslint-lsp",
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
}
