--- Terminal output → lines plus highlight ranges.
---
--- Tool output arrives with the escape sequences a terminal would have eaten.
--- Colours (SGR, `ESC[…m`) are turned into highlight ranges, everything else
--- (cursor moves, window titles, `\r` from progress bars) is dropped.

---@class Crust.Ui.Ansi
local M = {}

local Highlights = require("crust.ui.highlights")

---@class Crust.Ui.Ansi.Range
---@field line integer 1-based index into the returned lines
---@field col integer byte offset, 0-based
---@field end_col integer byte offset, exclusive
---@field group string highlight group

---@class Crust.Ui.Ansi.Parsed
---@field lines string[]
---@field ranges Crust.Ui.Ansi.Range[]

---@class Crust.Ui.Ansi.State
---@field color integer? 0-15 ansi color index
---@field bold boolean

--- Drop everything that is not a colour: OSC (window titles), non-SGR CSI
--- (cursor moves, erases), two-character escapes, and control characters.
--- `\r` becomes a newline so progress output keeps its shape.
---@param text string
---@return string
local function strip(text)
	text = text:gsub("\27%]%d*;.-[\7\27\\]", "")
	text = text:gsub("\27%[[%d;?]*[ -/]*[@-lo-~]", "") -- every CSI final except "m"
	text = text:gsub("\27[@-Z\\-_]", "")
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	-- Everything but \t, \n and the ESC of the colour codes parsed below.
	return (text:gsub("[%z\1-\8\11\12\14-\26\28-\31\127]", ""))
end

--- Fold one `ESC[…m` parameter list into the drawing state.
---@param params string
---@param state Crust.Ui.Ansi.State
local function apply(params, state)
	local codes = {}
	for code in (params == "" and "0" or params):gmatch("[^;]+") do
		codes[#codes + 1] = tonumber(code)
	end

	local index = 1
	while index <= #codes do
		local code = codes[index]
		if code == 0 then
			state.color, state.bold = nil, false
		elseif code == 1 then
			state.bold = true
		elseif code == 22 then
			state.bold = false
		elseif code == 39 then
			state.color = nil
		elseif code and code >= 30 and code <= 37 then
			state.color = code - 30
		elseif code and code >= 90 and code <= 97 then
			state.color = code - 90 + 8
		elseif code == 38 and codes[index + 1] == 5 then
			-- 256-colour; only the first 16 map onto the terminal palette.
			local extended = codes[index + 2]
			state.color = (extended and extended < 16) and extended or nil
			index = index + 2
		end
		index = index + 1
	end
end

--- Highlight group for the current state, or nil for default text.
--- Bold on a base colour is the bright variant, as most terminals draw it.
---@param state Crust.Ui.Ansi.State
---@return string?
local function group(state)
	if not state.color then
		return nil
	end
	local color = (state.bold and state.color < 8) and (state.color + 8) or state.color
	return Highlights.ANSI[color]
end

--- Split coloured text into plain lines and the ranges that colour them.
---@param text string
---@return Crust.Ui.Ansi.Parsed
function M.parse(text)
	---@type Crust.Ui.Ansi.State
	local state = { color = nil, bold = false }
	local lines, ranges = {}, {}

	for index, line in ipairs(vim.split(strip(text), "\n", { plain = true })) do
		local out, col, pos = {}, 0, 1

		---@param chunk string
		local function push(chunk)
			if chunk == "" then
				return
			end
			chunk = chunk:gsub("\27", "") -- an escape that started nothing
			out[#out + 1] = chunk
			local name = group(state)
			if name then
				ranges[#ranges + 1] = { line = index, col = col, end_col = col + #chunk, group = name }
			end
			col = col + #chunk
		end

		while true do
			local start, stop, params = line:find("\27%[([%d;]*)m", pos)
			if not start then
				break
			end
			push(line:sub(pos, start - 1))
			apply(params, state)
			pos = stop + 1
		end
		push(line:sub(pos))

		lines[index] = table.concat(out)
	end

	return { lines = lines, ranges = ranges }
end

return M
