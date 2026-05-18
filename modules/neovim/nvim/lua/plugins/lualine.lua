local icons = require("lazyvim.config").icons

return {
  "nvim-lualine/lualine.nvim",

  opts = function(_, opts)
    opts.sections.lualine_a = {
      {
        "mode",
        fmt = string.lower,
      },
    }

    -- Rebuild `lualine_c` rather than removing entries by index. The filename
    -- (`pretty_path`) is omitted on purpose because `incline.nvim` renders the
    -- path in the window header. Extras like `aerial` and `trouble` append to
    -- this list later, which is unaffected.
    opts.sections.lualine_c = {
      LazyVim.lualine.root_dir(),
      {
        "diagnostics",
        symbols = {
          error = icons.diagnostics.Error,
          warn = icons.diagnostics.Warn,
          info = icons.diagnostics.Info,
          hint = icons.diagnostics.Hint,
        },
      },
      {
        "fileformat",
        colored = true,
        separator = "",
        symbols = {
          unix = "", -- e712
          dos = "", -- e70f
          mac = "", -- e711
        },
      },
      { "filetype", icon_only = true, separator = "", padding = { left = 1, right = 0 } },
    }

    opts.sections.lualine_z = {}

    return opts
  end,
}
