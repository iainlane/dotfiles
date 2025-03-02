return {
	"nvim-treesitter/nvim-treesitter",

	opts = function(_, _)
		-- use bash syntax highlighting for zsh files in the absence of dedicated
		-- zsh support
		vim.treesitter.language.register("bash", "zsh")
	end,
}
