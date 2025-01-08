return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "AndreM222/copilot-lualine", "nvim-tree/nvim-web-devicons" },
  config = function()
    local lualine = require("lualine")
    local lazy_status = require("lazy.status") -- to configure lazy pending updates count

    lualine.setup({
      icons_enabled = true,

      options = {
        theme = "solarized",
      },
      sections = {
        lualine_a = {
          {
            function()
              return vim.fn.fnamemodify(vim.fn.getcwd(), ":t") -- obtiene solo el nombre del directorio de trabajo
            end,
          },
          {
            "mode",
            fmt = string.lower,
          },
        },
        lualine_b = {
          "branch",
        },
        lualine_c = {
          {
            "buffers",
            mode = 2,
          },
        },
        lualine_x = {
          {
            lazy_status.updates,
            cond = lazy_status.has_updates,
            color = { fg = "#ff9e64" },
          },
          { "copilot" },
          { "encoding" },
          { "fileformat" },
          { "filetype" },
        },
      },
    })
  end,
}
