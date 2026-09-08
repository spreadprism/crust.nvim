local M = {}

---@class Crust.Config
M.defaults = {}

---@type Crust.Config|nil
M.config = nil

---@type Crust.Config?
M.options = nil

function M.setup(opts)
	if M.options ~= nil then
		vim.notify("crust: setup() called more than once, overriding previous options", vim.log.levels.WARN)
	end
	M.options = opts
end

---@return Crust.Config
function M.get()
	if M.config == nil then
		M.config = vim.tbl_deep_extend("force", M.defaults, M.options or {})
	end

	return M.config
end

return M
