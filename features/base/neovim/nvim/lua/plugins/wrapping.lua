return {
  {
    "andrewferrier/wrapping.nvim",

    event = "BufRead",

    config = function()
      require("wrapping").setup()

      vim.api.nvim_create_autocmd("User", {
        pattern = "WrappingSet",
        callback = function(args)
          local data = args.data or {}
          local buf = data.buf or args.buf

          vim.b[buf].wrapping_mode = data.mode
          vim.cmd("redrawstatus")
        end,
      })
    end,
  },

  {
    "nvim-lualine/lualine.nvim",

    opts = function(_, opts)
      local wrapping_mode = {
        function()
          local mode = vim.b.wrapping_mode

          if mode == "hard" then
            return "󰉠 hard" -- nf-md-format_align_left
          end

          if mode == "soft" then
            return "󰦪 soft" -- nf-md-format_text_wrapping_wrap
          end

          return ""
        end,

        cond = function()
          return vim.b.wrapping_mode ~= nil
        end,
      }

      -- Slot in before `fileformat` (added by `lualine.lua`), falling back to
      -- an append if that component hasn't been registered.
      for i, entry in ipairs(opts.sections.lualine_c) do
        if entry[1] == "fileformat" then
          table.insert(opts.sections.lualine_c, i, wrapping_mode)
          return opts
        end
      end

      table.insert(opts.sections.lualine_c, wrapping_mode)
      return opts
    end,
  },
}
