return {
  "echasnovski/mini.ai",

  event = "VeryLazy",

  opts = function(_, opts)
    local ai = require("mini.ai")

    opts.custom_textobjects = vim.tbl_extend("error", opts.custom_textobjects, {
      -- Assignments with '='
      ["="] = ai.gen_spec.treesitter({
        a = "@assignment.outer",
        i = "@assignment.inner",
      }),
      -- Properties with ':'
      [":"] = ai.gen_spec.treesitter({
        a = "@property.outer",
        i = "@property.inner",
      }),
      -- Parameters/arguments with 'A'
      A = ai.gen_spec.treesitter({
        a = "@parameter.outer",
        i = "@parameter.inner",
      }),
      -- Function calls with 'F'
      F = ai.gen_spec.treesitter({
        a = "@call.outer",
        i = "@call.inner",
      }),
    })

    return opts
  end,
}
