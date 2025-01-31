return {
	"williamboman/mason.nvim",
	dependencies = {
		"williamboman/mason-lspconfig.nvim",
		"WhoIsSethDaniel/mason-tool-installer.nvim",
	},
	config = function()
		-- import mason
		local mason = require("mason")

		-- import mason-lspconfig
		local mason_lspconfig = require("mason-lspconfig")

		local mason_tool_installer = require("mason-tool-installer")

		-- enable mason and configure icons
		mason.setup({
			ui = {
				icons = {
					package_installed = "✓",
					package_pending = "➜",
					package_uninstalled = "✗",
				},
			},
		})

		mason_lspconfig.setup({
			automatic_installation = true, -- automatically install servers
			-- list of servers for mason to install
			ensure_installed = {
				"cssls",
				"emmet_ls",
				"golangci_lint_ls",
				"gopls",
				"graphql",
				"html",
				"jsonnet_ls",
				"lua_ls",
				"prismals",
				"pyright",
				"rust_analyzer",
				"sorbet", -- ruby
				"svelte",
				"tailwindcss",
				"ts_ls",
			},
		})

		mason_tool_installer.setup({
			ensure_installed = {
				"black", -- python formatter
				"eslint_d",
				"isort", -- python formatter
				"prettier", -- prettier formatter
				"pylint",
				"stylua", -- lua formatter
			},
		})
	end,
}
