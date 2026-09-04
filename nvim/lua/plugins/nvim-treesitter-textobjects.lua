-- LazyVim turns `opts.move.keys` into buffer-local motions, but always against
-- the `textobjects` query group. The scope and fold motions read the `locals`
-- and `folds` groups, and swapping has no `opts` interface at all, so both go
-- through the plugin's modules directly.

---@param key string
---@param method "goto_next_start"|"goto_previous_start"
---@param query string
---@param group string
---@param desc string
---@return LazyKeysSpec
local function move(key, method, query, group, desc)
  return {
    key,
    function()
      require("nvim-treesitter-textobjects.move")[method](query, group)
    end,
    mode = { "n", "x", "o" },
    desc = desc,
    silent = true,
  }
end

---@param key string
---@param direction "swap_next"|"swap_previous"
---@param query string
---@param desc string
---@return LazyKeysSpec
local function swap(key, direction, query, desc)
  return {
    key,
    function()
      require("nvim-treesitter-textobjects.swap")[direction](query, "textobjects")
    end,
    desc = desc,
    silent = true,
  }
end

return {
  "nvim-treesitter/nvim-treesitter-textobjects",

  opts = {
    move = {
      keys = {
        goto_next_start = {
          ["]f"] = "@call.outer",
          ["]m"] = "@function.outer",
          ["]c"] = "@class.outer",
          ["]i"] = "@conditional.outer",
          ["]l"] = "@loop.outer",
        },

        goto_next_end = {
          ["]F"] = "@call.outer",
          ["]M"] = "@function.outer",
          ["]C"] = "@class.outer",
          ["]I"] = "@conditional.outer",
          ["]L"] = "@loop.outer",
        },

        goto_previous_start = {
          ["[f"] = "@call.outer",
          ["[m"] = "@function.outer",
          ["[c"] = "@class.outer",
          ["[i"] = "@conditional.outer",
          ["[l"] = "@loop.outer",
        },

        goto_previous_end = {
          ["[F"] = "@call.outer",
          ["[M"] = "@function.outer",
          ["[C"] = "@class.outer",
          ["[I"] = "@conditional.outer",
          ["[L"] = "@loop.outer",
        },
      },
    },
  },

  keys = {
    move("]s", "goto_next_start", "@local.scope", "locals", "Next Scope"),
    move("[s", "goto_previous_start", "@local.scope", "locals", "Prev Scope"),
    move("]z", "goto_next_start", "@fold", "folds", "Next Fold"),
    move("[z", "goto_previous_start", "@fold", "folds", "Prev Fold"),

    swap("<leader>na", "swap_next", "@parameter.inner", "Swap parameter with next"),
    swap("<leader>n:", "swap_next", "@property.outer", "Swap property with next"),
    swap("<leader>nm", "swap_next", "@function.outer", "Swap function with next"),
    swap("<leader>Pa", "swap_previous", "@parameter.inner", "Swap parameter with previous"),
    swap("<leader>P:", "swap_previous", "@property.outer", "Swap property with previous"),
    swap("<leader>Pm", "swap_previous", "@function.outer", "Swap function with previous"),
  },
}
