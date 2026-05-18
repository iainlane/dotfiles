return {
  "nvim-lualine/lualine.nvim",

  opts = function(_, opts)
    opts.sections.lualine_a = {
      {
        "mode",
        fmt = string.lower,
      },
    }

    -- Drop the filename component: `incline.nvim` renders the path in the
    -- window header. `pretty_path` is the bare `{ <function> }` entry;
    -- `root_dir` and the trouble symbols breadcrumb also use a function at
    -- `[1]`, but they carry extra keys (`cond`, `color`).
    opts.sections.lualine_c = vim.tbl_filter(function(entry)
      return type(entry[1]) ~= "function" or vim.tbl_count(entry) > 1
    end, opts.sections.lualine_c)

    -- Slot `fileformat` in just before `filetype`, preserving any entries
    -- appended by extras (e.g. `aerial`).
    for i, entry in ipairs(opts.sections.lualine_c) do
      if entry[1] == "filetype" then
        table.insert(opts.sections.lualine_c, i, {
          "fileformat",
          colored = true,
          separator = "",
          symbols = {
            unix = "", -- e712
            dos = "", -- e70f
            mac = "", -- e711
          },
        })
        break
      end
    end

    opts.sections.lualine_z = {}

    return opts
  end,
}
