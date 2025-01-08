return {
  "akinsho/bufferline.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  enabled = false,
  version = "*",
  opts = {
    options = {
      color_icons = true,
      diagnostics = "nvim_lsp",
      mode = "buffers",
      show_buffer_icons = true,
    },
  },
}
