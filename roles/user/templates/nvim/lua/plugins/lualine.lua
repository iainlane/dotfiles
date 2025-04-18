return {
  "nvim-lualine/lualine.nvim",

  opts = function(_, opts)
    opts.sections.lualine_a = {
      {
        "mode",
        fmt = string.lower,
      },
    }

    -- Remove the filename - we handle this with `incline.nvim`. This is the
    -- penultimate element in the `c` section, before aerial.
    table.remove(opts.sections.lualine_c, #opts.sections.lualine_c - 1)

    -- Add a nice fileformat
    table.insert(opts.sections.lualine_c, 3, {
      "fileformat",
      colored = true,
      separator = "",
      symbols = {
        unix = "", -- e712
        dos = "", -- e70f
        mac = "", -- e711
      },
    })

    -- table.insert(opts.sections.lualine_c, {
    --   "buffers",
    --   mode = 4,
    --   use_mode_colors = true,
    -- })
    --
    opts.sections.lualine_z = {}

    return opts
  end,
}
