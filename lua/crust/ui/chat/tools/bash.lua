--- Display spec for the `bash` tool: command as title, output tail as body.
---
--- The output still carries the escape sequences a terminal would have eaten,
--- so it is run through `crust.ui.ansi`: colours become highlight ranges, the
--- rest is dropped.

local Ansi = require("crust.ui.ansi")

local MAX_BODY_LINES = 10

--- Last parse, keyed by the raw text, so `body` and `body_highlights` agree
--- without parsing twice per render.
---@type { text: string, lines: string[], ranges: Crust.Ui.Ansi.Range[] }?
local cache = nil

--- Parsed tail of the output: at most `MAX_BODY_LINES` lines with the ranges
--- that colour them, both shifted past the "… N more lines" header.
---@param display Crust.Chat.Tools.Display
---@return string[] lines
---@return Crust.Ui.Ansi.Range[] ranges
local function tail(display)
	local text = display:result_text() or ""
	if cache and cache.text == text then
		return cache.lines, cache.ranges
	end

	local parsed = Ansi.parse(vim.trim(text))
	local lines, ranges = parsed.lines, parsed.ranges

	local dropped = #lines - MAX_BODY_LINES
	if dropped > 0 then
		lines = vim.list_slice(lines, dropped + 1, #lines)
		table.insert(lines, 1, "… " .. dropped .. " more lines")

		local kept = {}
		for _, range in ipairs(ranges) do
			if range.line > dropped then
				-- -dropped for the cut, +1 for the header line.
				range.line = range.line - dropped + 1
				kept[#kept + 1] = range
			end
		end
		ranges = kept
	end

	cache = { text = text, lines = lines, ranges = ranges }
	return lines, ranges
end

---@type Crust.Chat.Tools.Spec
return {
	title_lang = "bash",
	title = function(display)
		local command = display.args.command
		if type(command) ~= "string" or command == "" then
			return ""
		end
		return (command:gsub("%s+", " "))
	end,
	-- The preview has room for the command as it was written, newlines,
	-- heredocs and all.
	preview_title = function(display)
		local command = display.args.command
		return type(command) == "string" and command ~= "" and command or nil
	end,
	body = function(display)
		local text = display:result_text()
		if not text or text == "" then
			return nil
		end
		return (tail(display))
	end,
	body_highlights = function(display)
		local _, ranges = tail(display)
		return ranges
	end,
}
