return {
  "zbirenbaum/copilot.lua",
  cmd = "Copilot",
  event = "InsertEnter",
  opts = {
    filetypes = {
      ["*"] = true,
    },
    panel = {
      enabled = false,
    },
    suggestion = {
      enabled = false,
    },
  },
}
