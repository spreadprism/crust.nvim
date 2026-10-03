--- Shared result excerpt for tool specs.
---
--- A tool result is terminal output as often as not, so it goes through
--- `crust.ui.ansi`: colours become highlight ranges, the rest is dropped.
--- Only a handful of lines are kept, either the first ones (a result that
--- arrives whole, where the top says what happened) or the last ones (a
--- command still running, where the bottom is the news).

---@class Crust.Chat.Tools.Excerpt
local M = {}

local Ansi = require("crust.ui.ansi")

--- Lines kept when the caller does not say otherwise.
M.MAX_LINES = 10

---@class Crust.Chat.Tools.Excerpt.Opts
---@field max_lines? integer defaults to `MAX_LINES`
---@field from? "head"|"tail" which end of the output to keep, default "tail"

--- Last parse, so `body` and `body_highlights` of the same render agree
--- without parsing twice.
---@type { key: string, lines: string[], ranges: Crust.Ui.Ansi.Range[] }?
local cache = nil

---@param count integer
---@return string
local function more(count)
	return "… " .. count .. " more line" .. (count == 1 and "" or "s")
end

--- Parsed excerpt of a call's result: the kept lines and the ranges that
--- colour them, both shifted onto the lines they end up on.
---@param display Crust.Chat.Tools.Display
---@param opts? Crust.Chat.Tools.Excerpt.Opts
---@return string[] lines
---@return Crust.Ui.Ansi.Range[] ranges
function M.of(display, opts)
	opts = opts or {}
	local max = opts.max_lines or M.MAX_LINES
	local from = opts.from or "tail"

	local text = display:result_text() or ""
	local key = from .. ":" .. max .. ":" .. text
	if cache and cache.key == key then
		return cache.lines, cache.ranges
	end

	local parsed = Ansi.parse(vim.trim(text))
	local lines, ranges = parsed.lines, parsed.ranges
	local dropped = #lines - max

	if dropped > 0 and from == "tail" then
		lines = vim.list_slice(lines, dropped + 1, #lines)
		table.insert(lines, 1, more(dropped))

		local kept = {}
		for _, range in ipairs(ranges) do
			if range.line > dropped then
				-- -dropped for the cut, +1 for the header line.
				range.line = range.line - dropped + 1
				kept[#kept + 1] = range
			end
		end
		ranges = kept
	elseif dropped > 0 then
		lines = vim.list_slice(lines, 1, max)
		lines[#lines + 1] = more(dropped)

		local kept = {}
		for _, range in ipairs(ranges) do
			if range.line <= max then
				kept[#kept + 1] = range
			end
		end
		ranges = kept
	end

	cache = { key = key, lines = lines, ranges = ranges }
	return lines, ranges
end

return M
