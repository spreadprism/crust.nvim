--- Display spec for the `bash` tool: command as title, output tail as body.
---
--- The parsing and cutting is `crust.ui.chat.tools.excerpt`; bash keeps the
--- last lines, which is where a running command writes.

local Excerpt = require("crust.ui.chat.tools.excerpt")

---@param display Crust.Chat.Tools.Display
---@return string[] lines
---@return Crust.Ui.Ansi.Range[] ranges
local function tail(display)
	return Excerpt.of(display, { from = "tail" })
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
