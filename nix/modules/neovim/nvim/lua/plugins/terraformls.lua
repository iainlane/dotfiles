return {
  "neovim/nvim-lspconfig",

  opts = {
    servers = {
      -- terraform-ls produces large log files: override the command to discard
      -- them
      terraformls = {
        cmd = { "terraform-ls", "serve", "-log-file", "/dev/null" },
      },
    },
  },
}
