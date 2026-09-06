return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      ansiblels = {
        settings = {
          ansible = {
            validation = {
              lint = {
                -- ansible-lint's yaml rules disagree with the way prettier
                -- formats these files, so skip those rules
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
