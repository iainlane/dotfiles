return {
  "nvim-mini/mini.ai",

  opts = function(_, opts)
    local ai = require("mini.ai")

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

    -- Create custom_textobjects for mini.ai
    local custom_objects = {}
    for key, obj in pairs(textobjects) do
      custom_objects[key] = ai.gen_spec.treesitter(obj.treesitter)
    end

    opts.custom_textobjects = vim.tbl_extend("error", opts.custom_textobjects or {}, custom_objects)

    -- Register with which-key (following LazyVim structure)
    local wk_mappings = { mode = { "o", "x" } }

    -- Add group labels
    table.insert(wk_mappings, { "a", group = "Around" })
    table.insert(wk_mappings, { "i", group = "Inside" })

    -- Add each textobject with description
    for key, obj in pairs(textobjects) do
      table.insert(wk_mappings, { "a" .. key, desc = obj.desc })
      table.insert(wk_mappings, { "i" .. key, desc = obj.desc })
    end

    if vim.g.vscode == nil then
      local wk = require("which-key")
      wk.add(wk_mappings)
    end

    return opts
  end,
}
