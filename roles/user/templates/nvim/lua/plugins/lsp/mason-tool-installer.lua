return {
  "WhoIsSethDaniel/mason-tool-installer.nvim",

  event = "VeryLazy",

  opts = {
    ensure_installed = {
      "black", -- python formatter
      "eslint_d",
      "isort", -- python formatter
      "prettier", -- prettier formatter
      "pylint",
      "stylua", -- lua formatter
    },
  },
}
