--- Scratch buffer creation shared by the chat panels.

local Filetypes = require("crust.filetypes")

---@param name string buffer name, wiped first if it already exists
---@param filetype string crust filetype, e.g. "crust_output"
---@param highlight? boolean attach treesitter, default false
---@return integer buf
return function(name, filetype, highlight)
	Filetypes.setup()

	local existing = vim.fn.bufnr(name)
	if existing ~= -1 then
		vim.api.nvim_buf_delete(existing, { force = true })
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = filetype
	vim.api.nvim_buf_set_name(buf, name)

	-- The filetype is ours, so highlighting has to be attached explicitly.
	-- The parser is resolved through the registration in crust.filetypes.
	if highlight then
		pcall(vim.treesitter.start, buf)
	end

	return buf
end
