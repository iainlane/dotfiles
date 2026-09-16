-- Vale through vale-ls, reading the global configuration that home-manager
-- writes for prose-lint, so the editor reports the same Prose style findings
-- as the hooks. The file types are the ones that configuration has a parser
-- or a comment mapping for.
local config_home = vim.env.XDG_CONFIG_HOME or vim.fn.expand("~/.config")

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        vale_ls = {
          filetypes = {
            "markdown",
            "text",
            "asciidoc",
            "rst",
            "nix",
            "sh",
            "bash",
            "toml",
            "yaml",
            "go",
            "rust",
            "python",
            "typescript",
            "typescriptreact",
            "javascript",
            "javascriptreact",
            "c",
            "cpp",
            "java",
            "lua",
            "ruby",
            "swift",
          },
          root_markers = { ".vale.ini", ".git" },
          init_options = {
            configPath = config_home .. "/vale/.vale.ini",
            installVale = false,
            syncOnStartup = false,
          },
        },
      },
    },
  },
}
