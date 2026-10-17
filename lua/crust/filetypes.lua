--- Crust filetypes and their treesitter mapping.

---@class Crust.Filetypes
local M = {}

M.input = "crust_input"
M.output = "crust_output"
M.ask = "crust_ask"

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
	vim.treesitter.language.register("markdown", M.ask)
end

return M
