local M = {}

---@class Crust.Config.Icons
---@field pending string
---@field success string
---@field error string

---@class Crust.Config.Labels
---@field user string
---@field agent string

---@class Crust.Config.Log
---@field enabled boolean write the raw rpc transcript to disk
---@field dir string directory holding `crust-<session>.log` files

---@class Crust.Config
---@field bin string
---@field log Crust.Config.Log
---@field icons Crust.Config.Icons status icons shown before a tool title
---@field labels Crust.Config.Labels message icons, same glyphs as pi.nvim
---@field timestamp_format string passed to os.date for message timestamps
M.defaults = {
	bin = "pi",
	icons = {
		pending = "󰔟",
		success = "󰄬",
		error = "󰅖",
	},
	labels = {
		user = "",
		agent = "󰚩",
	},
	timestamp_format = "%b %-d %Y, %H:%M",
	log = {
		enabled = true,
		dir = vim.fn.stdpath("state") .. "/crust",
	},
}

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
