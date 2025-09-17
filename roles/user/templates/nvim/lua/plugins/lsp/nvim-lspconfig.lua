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

      gh_actions_ls = {},
    },
  },
}
