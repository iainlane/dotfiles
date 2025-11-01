return {
  "mason-org/mason.nvim",

  opts = {
    ensure_installed = {
      "alejandra", -- nix formatter
      "htmlbeautifier", -- html formatter
      "jsonnetfmt", -- jsonnet formatter
    },
  },
}
