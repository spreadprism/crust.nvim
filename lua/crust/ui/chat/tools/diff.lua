--- Shared diff accounting for tool specs that write files (`edit`, `write`).

local M = {}

--- Added and removed line counts from `result.details.diff`, or nil when there
--- is none.
---@param display Crust.Chat.Tools.Display
---@return integer? added
---@return integer? removed
function M.counts(display)
	local details = display.result and display.result.details
	local diff = details and details.diff
	if type(diff) ~= "string" then
		return nil, nil
	end

	local added, removed = 0, 0
	for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
		local first = line:sub(1, 1)
		if first == "+" then
			added = added + 1
		elseif first == "-" then
			removed = removed + 1
		end
	end
	return added, removed
end

--- Path argument shortened for display, or "" when absent.
---@param display Crust.Chat.Tools.Display
---@return string
function M.title(display)
	local path = display.args.path or display.args.file_path
	if type(path) ~= "string" or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":~:.")
end

return M
