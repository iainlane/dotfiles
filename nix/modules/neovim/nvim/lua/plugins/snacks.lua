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

      -- Smooth scrolling.
      scroll = { enabled = true },

      -- Inline images via the Kitty graphics protocol.
      image = { enabled = true },

      -- Dim inactive scopes; pairs nicely with `mini.indentscope` and treesitter
      -- context. Off by default; toggle with `<leader>uD`.
      dim = {},

      -- Distraction-free writing mode (`<leader>z`).
      zen = {},

      -- Project-scoped scratch buffers (`<leader>.` toggles, `<leader>S` lists).
      scratch = {},
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
      {
        "<leader>.",
        function()
          Snacks.scratch()
        end,
        desc = "Toggle Scratch Buffer",
      },
      {
        "<leader>S",
        function()
          Snacks.scratch.select()
        end,
        desc = "Select Scratch Buffer",
      },
      {
        "<leader>z",
        function()
          Snacks.zen()
        end,
        desc = "Toggle Zen Mode",
      },
      {
        "<leader>Z",
        function()
          Snacks.zen.zoom()
        end,
        desc = "Toggle Zoom",
      },
      {
        "<leader>uD",
        function()
          vim.g.snacks_dim = not vim.g.snacks_dim
          if vim.g.snacks_dim then
            Snacks.dim.enable()
          else
            Snacks.dim.disable()
          end
        end,
        desc = "Toggle Dim",
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
