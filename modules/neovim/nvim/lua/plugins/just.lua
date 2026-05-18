-- TODO: Remove when https://github.com/LazyVim/LazyVim/pull/6937 is merged, and
-- use the extra.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "just" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        just = {},
      },
    },
  },
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters_by_ft = {
        just = { "just" },
      },
    },
  },
}
