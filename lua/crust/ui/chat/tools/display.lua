--- One tool call's rendered state.
---
--- A display is built from a spec:
---   title   string|fun(display): string   shown after the tool name
---   body    fun(display): string[]|string|nil   optional detail lines
---   inline  boolean   render the body on the title line
---
--- A rendered call is three highlighted segments:
---   <icon> <name: CrustTool> <title: CrustToolTitle> <body: CrustToolBodyInline>
--- or, when not inline, body lines below it highlighted as CrustToolBody.
---
--- Per-tool specs live next to this file (see `crust.ui.chat.tools`).

---@alias Crust.Chat.Tools.Status "pending"|"success"|"error"

---@class Crust.Chat.Tools.Spec
---@field title? string|fun(display: Crust.Chat.Tools.Display): string
---@field body? fun(display: Crust.Chat.Tools.Display): string[]|string|nil
---@field inline? boolean render the body on the title line instead of under it

---@class Crust.Chat.Tools.Display
---@field name string tool name
---@field args table arguments of the call
---@field status Crust.Chat.Tools.Status
---@field result Crust.Pi.ToolResult? set when the call ends
---@field spec Crust.Chat.Tools.Spec
local Display = {}
Display.__index = Display

local Config = require("crust.config")
local Highlights = require("crust.ui.highlights")

---@class Crust.Chat.Tools.Highlight
---@field line integer 1-based index into the rendered lines
---@field col integer byte offset, 0-based
---@field end_col integer byte offset, exclusive
---@field group string highlight group

---@class Crust.Chat.Tools.Render
---@field lines string[]
---@field highlights Crust.Chat.Tools.Highlight[]

---@type table<Crust.Chat.Tools.Status, string>
local FALLBACK_ICONS = {
	pending = "⋯",
	success = "✓",
	error = "✗",
}

---@param name string
---@param spec Crust.Chat.Tools.Spec
---@param args? table
---@return Crust.Chat.Tools.Display
function Display.new(name, spec, args)
	local self = setmetatable({}, Display)
	self.name = name
	self.spec = spec
	self.args = args or {}
	self.status = "pending"
	self.result = nil
	return self
end

--- Fold an rpc tool event into the display state.
---@param event Crust.Pi.Event
function Display:update(event)
	if event.args then
		self.args = event.args
	end

	if event.type == "tool_execution_end" then
		self.result = event.result --[[@as Crust.Pi.ToolResult]]
		self.status = event.isError and "error" or "success"
	elseif event.partialResult then
		self.result = event.partialResult
	end
end

---@param status Crust.Chat.Tools.Status
function Display:set_status(status)
	self.status = status
end

--- Concatenated text content of the tool result, if any.
---@return string?
function Display:result_text()
	local content = self.result and self.result.content
	if type(content) ~= "table" then
		return nil
	end

	local parts = {}
	for _, item in ipairs(content) do
		if item.type == "text" and item.text then
			parts[#parts + 1] = item.text
		end
	end

	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

--- Status icon, from `config.icons` with an ascii-ish fallback.
---@return string
function Display:icon()
	local icons = Config.get().icons or {}
	return icons[self.status] or FALLBACK_ICONS[self.status] or FALLBACK_ICONS.pending
end

--- Detail shown after the tool name, e.g. a path or a command.
---@return string
function Display:title()
	local title = self.spec.title
	if type(title) == "function" then
		title = title(self)
	end
	return title or ""
end

---@return string[]
function Display:body()
	local body = self.spec.body and self.spec.body(self)
	if not body then
		return {}
	end
	if type(body) == "string" then
		return vim.split(body, "\n", { plain = true })
	end
	return body
end

--- True when the spec asks for a single-line rendering.
---@return boolean
function Display:is_inline()
	return self.spec.inline == true
end

--- Lines plus their highlight ranges.
---@return Crust.Chat.Tools.Render
function Display:render()
	local icon = self:icon()
	local title = self:title()
	local body = self:body()

	local head = icon .. " " .. self.name
	local highlights = {
		{ line = 1, col = 0, end_col = #icon, group = Highlights.tool_icon[self.status] },
		{ line = 1, col = #icon + 1, end_col = #head, group = Highlights.TOOL },
	}

	if title ~= "" then
		local col = #head + 1
		head = head .. " " .. title
		highlights[#highlights + 1] = { line = 1, col = col, end_col = #head, group = Highlights.TOOL_TITLE }
	end

	local lines = { head }

	if self:is_inline() then
		if #body > 0 then
			local col = #head + 1
			lines[1] = head .. " " .. table.concat(body, " ")
			highlights[#highlights + 1] =
				{ line = 1, col = col, end_col = #lines[1], group = Highlights.TOOL_BODY_INLINE }
		end
		return { lines = lines, highlights = highlights }
	end

	for _, line in ipairs(body) do
		lines[#lines + 1] = "  " .. line
		highlights[#highlights + 1] =
			{ line = #lines, col = 0, end_col = #lines[#lines], group = Highlights.TOOL_BODY }
	end

	return { lines = lines, highlights = highlights }
end

--- Rendered lines without highlight information.
---@return string[]
function Display:lines()
	return self:render().lines
end

return Display
