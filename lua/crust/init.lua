local M = {}

function M.setup()
	if vim.fn.has("nvim-0.13") == 0 then
		vim.log.error("crust.nvim requires nvim-0.13 features")
		return
	end
end

return M
