--- Scratch buffer creation shared by the chat panels.

---@param name string buffer name, wiped first if it already exists
---@param filetype string
---@return integer buf
return function(name, filetype)
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

	return buf
end
