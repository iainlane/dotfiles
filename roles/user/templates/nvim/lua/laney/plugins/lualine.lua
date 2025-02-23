return {
  "nvim-lualine/lualine.nvim",

  opts = function(_, opts)
    opts.sections.lualine_a = {
      {
        "mode",
        fmt = string.lower,
      },
    }

    table.insert(opts.sections.lualine_c, 4, { "encoding" })
    table.insert(opts.sections.lualine_c, 4, {
      "fileformat",
      separator = "",
      symbols = {
        unix = "", -- e712
        dos = "", -- e70f
        mac = "", -- e711
      },
    })
    table.insert(opts.sections.lualine_c, {
      "buffers",
      mode = 4,
      use_mode_colors = true,
    })

    opts.sections.lualine_z = {}

    return opts
  end,
}
