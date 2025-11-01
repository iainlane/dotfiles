return {
  {
    "vhyrro/luarocks.nvim",
    priority = 1000,
    opts = {
      rocks = { "tiktoken_core" },
    },
  },

  {
    "CopilotC-Nvim/CopilotChat.nvim",

    build = "make tiktoken",
  },
}
