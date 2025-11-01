return {
  {
    "snacks.nvim",

    opts = {
      indent = {
        indent = {
          hl = {
            "SnacksIndent1",
            "SnacksIndent2",
            "SnacksIndent3",
            "SnacksIndent4",
            "SnacksIndent5",
            "SnacksIndent6",
            "SnacksIndent7",
            "SnacksIndent8",
          },
        },
      },
    },

    keys = {
      { "<leader>n", false },
      {
        "<leader>N",
        function()
          if Snacks.config.picker and Snacks.config.picker.enabled then
            Snacks.picker.notifications()
          else
            Snacks.notifier.show_history()
          end
        end,
        desc = "Notification History",
      },
      {
        "<leader>uN",
        function()
          Snacks.notifier.hide()
        end,
        desc = "Dismiss All Notifications",
      },
      {
        "<leader>sB",
        function()
          local buffer_dir = vim.fn.expand("%:p:h")
          Snacks.picker.grep({
            dirs = { buffer_dir },
            title = "Grep (" .. vim.fn.fnamemodify(buffer_dir, ":~") .. ")",
          })
        end,
        desc = "Grep (Buffer directory)",
      },
    },
  },

  {
    "folke/which-key.nvim",
    optional = true,
    opts = function(_, opts)
      opts.spec = opts.spec or {}
      table.insert(opts.spec, {
        { "<leader>sB", icon = {
          hl = "MiniIconsAzure",
          icon = "󱡠 ",
        } },
      })
    end,
  },
}
