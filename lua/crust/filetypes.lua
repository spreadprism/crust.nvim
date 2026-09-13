--- Crust filetypes and their treesitter mapping.

---@class Crust.Filetypes
local M = {}

M.input = "crust_input"
M.output = "crust_output"

local registered = false

--- Map both filetypes to the markdown parser so `vim.treesitter.start(buf)`
--- highlights them without knowing the language.
function M.setup()
	if registered then
		return
	end
	registered = true

	vim.treesitter.language.register("markdown", M.input)
	vim.treesitter.language.register("markdown", M.output)
end

return M
