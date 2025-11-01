return {
  "saghen/blink.cmp",

  dependencies = { "fang2hou/blink-copilot" },

  opts = {
    completion = {
      trigger = {
        show_in_snippet = false,
      },
    },
    keymap = {
      preset = "super-tab",
    },
    signature = {
      enabled = true,
    },

    sources = {
      default = { "copilot" },
      providers = {
        copilot = {
          name = "copilot",
          module = "blink-copilot",
          score_offset = 100,
          async = true,
        },
      },
    },
  },
}
