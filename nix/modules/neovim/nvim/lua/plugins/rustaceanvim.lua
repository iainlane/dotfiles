return {
  "mrcjkb/rustaceanvim",
  opts = function()
    vim.g.rustaceanvim = {
      server = {
        default_settings = {
          ["rust-analyzer"] = {
            procMacro = {
              enable = true,
            },
          },
        },
      },
    }
  end,
}
