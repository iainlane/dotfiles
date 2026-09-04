---Treesitter text objects to add to LazyVim's mini.ai set, keyed by the
---character that follows `a` or `i`.
local textobjects = {
  ["="] = {
    treesitter = {
      a = "@assignment.outer",
      i = "@assignment.inner",
    },
    desc = "Assignment",
  },
  [":"] = {
    treesitter = {
      a = "@property.outer",
      i = "@property.inner",
    },
    desc = "Property",
  },
  A = {
    treesitter = {
      a = "@parameter.outer",
      i = "@parameter.inner",
    },
    desc = "Parameter/Argument",
  },
  F = {
    treesitter = {
      a = "@call.outer",
      i = "@call.inner",
    },
    desc = "Function Call",
  },
  C = {
    treesitter = {
      a = "@comment.outer",
      i = "@comment.inner",
    },
    desc = "Comment",
  },
}

return {
  {
    "nvim-mini/mini.ai",

    opts = function(_, opts)
      local ai = require("mini.ai")

      opts.custom_textobjects = opts.custom_textobjects or {}

      for key, obj in pairs(textobjects) do
        opts.custom_textobjects[key] = ai.gen_spec.treesitter(obj.treesitter)
      end
    end,
  },

  {
    "folke/which-key.nvim",

    optional = true,

    opts = function(_, opts)
      -- `LazyVim.mini.ai_whichkey` describes mini.ai's own text objects from a
      -- fixed list, so the ones added above need their own entries.
      local spec = { mode = { "o", "x" } }

      for key, obj in pairs(textobjects) do
        table.insert(spec, { "a" .. key, desc = obj.desc })
        table.insert(spec, { "i" .. key, desc = obj.desc })
      end

      opts.spec = opts.spec or {}
      table.insert(opts.spec, spec)
    end,
  },
}
