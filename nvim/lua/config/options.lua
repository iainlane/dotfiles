local opt = vim.opt

opt.relativenumber = true
opt.number = not vim.g.vscode

-- tabs & indentation
opt.tabstop = 2 -- prettier's default
opt.shiftwidth = 2
opt.expandtab = true
opt.autoindent = true -- copy the current line's indent when starting a new one
opt.smartindent = true

opt.tw = 80
opt.wrap = false

opt.hlsearch = false

-- search settings
opt.ignorecase = true
opt.smartcase = true -- case-insensitive unless the pattern has an upper-case character

opt.cursorline = true

-- 24-bit colour, which catppuccin needs. The terminal has to support it.
opt.termguicolors = true
opt.signcolumn = "yes" -- always drawn, so text does not shift when a sign appears

opt.backspace = "indent,eol,start" -- backspace over indent, line ends and where insert began

-- split windows
opt.splitright = true
opt.splitbelow = true

opt.swapfile = false

vim.g.maplocalleader = ","

-- Rust diagnostics come from bacon-ls. `bacon` and `bacon-ls` are provided
-- by Nix `extraPackages`.
vim.g.lazyvim_rust_diagnostics = "bacon-ls"

vim.g.netrw_liststyle = 3

-- The files that mark the root of one language module. `config/autocmds.lua`
-- reads this too.
vim.g.language_module_markers = {
  "go.work",
  "go.mod",
  "Cargo.toml",
  "pyproject.toml",
  "package.json",
}

-- In monorepos, prefer the nearest language-module root over the outer
-- `.git` so pickers, grep and project tools scope to the submodule being
-- edited. LazyVim treats an inner array as "any of these markers, equal
-- priority", so no further nesting is needed here.
vim.g.root_spec = {
  "lsp",
  vim.g.language_module_markers,
  { ".git", "lua" },
  "cwd",
}
