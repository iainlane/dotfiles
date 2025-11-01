return {
  "gbprod/substitute.nvim",

  event = { "BufReadPre", "BufNewFile" },

  keys = {
    {
      "<leader>is",
      function()
        require("substitute").operator()
      end,
      desc = "Substitute with motion",
    },
    {
      "<leader>ii",
      function()
        require("substitute").line()
      end,
      desc = "Substitute line",
    },
    {
      "<leader>iI",
      function()
        require("substitute").eol()
      end,
      desc = "Substitute to end of line",
    },
    {
      "<leader>i",
      function()
        require("substitute").visual()
      end,
      mode = { "x" },
      desc = "Substitute",
    },
  },

  config = function()
    local substitute = require("substitute")

    substitute.setup({
      on_substitute = require("yanky.integration").substitute(),
    })

    local whichkey = require("which-key")

    whichkey.add({
      { "<leader>i", group = "substitute", icon = { icon = "", color = "blue" } },
    })
  end,
}
