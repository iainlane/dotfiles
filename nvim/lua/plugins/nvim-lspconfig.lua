return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      ansiblels = {
        settings = {
          ansible = {
            validation = {
              lint = {
                -- this is also handled by prettier, and they don't quite agree
                arguments = "--skip-list=yaml",
              },
            },
          },
        },
      },

      cssls = {},
      emmet_language_server = {},

      -- nixpkgs has no `gh-actions-language-server`, so this server runs only
      -- when the binary is on `PATH` some other way. `mason = false` keeps
      -- Mason from downloading a copy of its own.
      gh_actions_ls = {
        enabled = vim.fn.executable("gh-actions-language-server") == 1,
        mason = false,
      },
    },
  },
}
