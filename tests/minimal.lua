-- Minimal nvim config: only crust.nvim loaded, no user config.
vim.opt.rtp:append(vim.fn.getcwd())

vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.number = true

require("crust").setup({
	mcp = { enabled = true },
})
vim.notify("crust.nvim loaded — try :Crust chat", vim.log.levels.INFO)
