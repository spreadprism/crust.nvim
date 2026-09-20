--- @mention highlighting for the input and output buffers.
---
--- A mention is an `@` followed by non-blank text, the same word the file
--- completion produces: a space ends it, so `@` in prose stays plain.

---@class Crust.Mentions.Range
---@field col integer byte offset, 0-based
---@field end_col integer byte offset, exclusive

---@class Crust.Mentions
local M = {}

M.GROUP = require("crust.ui.highlights").MENTION

--- Marks live in their own namespace so a refresh never touches the
--- highlights the output panel owns.
M.ns = vim.api.nvim_create_namespace("crust.mentions")

--- Lua patterns have no alternation, so the trailing punctuation a mention
--- must not swallow is trimmed after matching.
local TRAILING = "[%.,;:!%?%)%]}\"']+$"

--- Mention ranges on a single line.
---@param line string
---@return Crust.Mentions.Range[]
function M.ranges(line)
	local ranges = {}

	local init = 1
	while true do
		local first, last = line:find("@%S+", init)
		if not first then
			break
		end
		init = last + 1

		-- `a@b` is an address or a handle in the middle of a word, not a
		-- mention: the trigger has to start a word.
		if first == 1 or line:sub(first - 1, first - 1):match("%s") then
			local text = line:sub(first, last):gsub(TRAILING, "")
			if #text > 1 then
				ranges[#ranges + 1] = { col = first - 1, end_col = first - 1 + #text }
			end
		end
	end

	return ranges
end

--- Highlight every mention on a row range, replacing the previous marks.
---@param buf integer
---@param first? integer 0-based row, defaults to the whole buffer
---@param last? integer exclusive, -1 for the end of the buffer
function M.highlight(buf, first, last)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	first = first or 0
	last = last or -1

	local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
	local stop = last == -1 and first + #lines or last
	vim.api.nvim_buf_clear_namespace(buf, M.ns, first, stop)

	for index, line in ipairs(lines) do
		for _, range in ipairs(M.ranges(line)) do
			vim.api.nvim_buf_set_extmark(buf, M.ns, first + index - 1, range.col, {
				end_col = range.end_col,
				hl_group = M.GROUP,
			})
		end
	end
end

--- Keep `buf` highlighted while it is edited, e.g. the input buffer.
---@param buf integer
function M.attach(buf)
	M.highlight(buf)

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		group = vim.api.nvim_create_augroup("crust.mentions." .. buf, { clear = true }),
		buffer = buf,
		callback = function()
			M.highlight(buf)
		end,
	})
end

return M
