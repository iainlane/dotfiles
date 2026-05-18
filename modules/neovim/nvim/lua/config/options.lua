local opt = vim.opt

opt.relativenumber = true
opt.number = not vim.g.vscode

-- tabs & indentation
opt.tabstop = 2 -- 2 spaces for tabs (prettier default)
opt.shiftwidth = 2 -- 2 spaces for indent width
opt.expandtab = true -- expand tab to spaces
opt.autoindent = true -- copy indent from current line when starting new one
opt.smartindent = true

opt.tw = 80
opt.wrap = false

opt.hlsearch = false

-- search settings
opt.ignorecase = true -- ignore case when searching
opt.smartcase = true -- if you include mixed case in your search, assumes you want case-sensitive

opt.cursorline = true

-- turn on termguicolors for tokyonight colorscheme to work
-- (have to use iterm2 or any other true color terminal)
opt.termguicolors = true
opt.signcolumn = "yes" -- show sign column so that text doesn't shift

-- backspace
opt.backspace = "indent,eol,start" -- allow backspace on indent, end of line or insert mode start position

-- split windows
opt.splitright = true -- split vertical window to the right
opt.splitbelow = true -- split horizontal window to the bottom

-- turn off swapfile
opt.swapfile = false

vim.g.maplocalleader = ","

-- Use bacon-ls for Rust diagnostics instead of rust-analyzer. `bacon` and
-- `bacon-ls` are provided by Nix `extraPackages`.
vim.g.lazyvim_rust_diagnostics = "bacon-ls"

vim.g.netrw_liststyle = 3
-- In monorepos, prefer the nearest language-module root over the outer
-- `.git` so pickers, grep and project tools scope to the submodule you are
-- editing rather than the whole repository. LazyVim treats an inner array
-- as "any of these markers, equal priority", so no further nesting is
-- needed here (unlike `vim.fs.root`).
vim.g.root_spec = {
  "lsp",
  {
    "go.work",
    "go.mod",
    "Cargo.toml",
    "pyproject.toml",
    "package.json",
  },
  { ".git", "lua" },
  "cwd",
}
