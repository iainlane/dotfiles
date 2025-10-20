return {
  "neovim/nvim-lspconfig",

  opts = {
    servers = {
      terraformls = {
        cmd = { "terraform-ls", "serve", "-log-file", "/dev/null" },
      },
    },
  },
}
