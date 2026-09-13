--- One tool call's rendered state.
---
--- A display is built from a spec:
---   title   string|fun(display): string   shown after the tool name
---   body    fun(display): string[]|string|nil   optional detail lines
---   inline  boolean|fun(display): boolean   render the body on the title line
---   title_lang  string   treesitter language for the title, e.g. "bash"
---   body_lang   string   treesitter language for the body
---
--- A rendered call is three highlighted segments:
---   <icon> <name: CrustTool>: <title: CrustToolTitle> <body: CrustToolBodyInline>
--- or, when not inline, body lines below it highlighted as CrustToolBody.
---
--- Per-tool specs live next to this file (see `crust.ui.chat.tools`).

---@alias Crust.Chat.Tools.Status "pending"|"success"|"error"

---@class Crust.Chat.Tools.Spec
---@field title? string|fun(display: Crust.Chat.Tools.Display): string
---@field body? fun(display: Crust.Chat.Tools.Display): string[]|string|nil
---@field inline? boolean|fun(display: Crust.Chat.Tools.Display): boolean render the body on the title line instead of under it
---@field title_lang? string treesitter language used to highlight the title
---@field body_lang? string treesitter language used to highlight the body
---@field title_prefix? string written before the title, e.g. "> "
---@field body_prefix? string written before each body line, default two spaces

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
local Syntax = require("crust.ui.syntax")

---@class Crust.Chat.Tools.Highlight
---@field line integer 1-based index into the rendered lines
---@field col integer byte offset, 0-based
---@field end_col integer byte offset, exclusive
---@field group string highlight group
---@field priority? integer extmark priority, backgrounds sit below the text

---@class Crust.Chat.Tools.Render
---@field lines string[]
---@field highlights Crust.Chat.Tools.Highlight[]
---@field line_highlights table<integer, string> full-line background per line

--- Backgrounds are drawn under the syntax highlights, which only set colors.
local BACKGROUND_PRIORITY = 100

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

--- True when the spec asks for a single-line rendering. Specs can decide per
--- call, e.g. inline on success and multi-line on error.
---@return boolean
function Display:is_inline()
	local inline = self.spec.inline
	if type(inline) == "function" then
		return inline(self) == true
	end
	return inline == true
end

--- Treesitter ranges for `text`, shifted into the rendered layout.
--- Returns nil when the language is unavailable, so callers can fall back
--- to a flat highlight group.
---@param text string
---@param lang string?
---@param line integer rendered line holding the first line of `text`
---@param col integer byte offset of `text` on that line
---@param continuation? integer byte offset of the following lines, default `col`
---@return Crust.Chat.Tools.Highlight[]?
local function syntax_highlights(text, lang, line, col, continuation)
	if not lang then
		return nil
	end

	local ranges = Syntax.highlight(text, lang)
	if not ranges or #ranges == 0 then
		return nil
	end

	local highlights = {}
	for _, range in ipairs(ranges) do
		-- Only the first line starts at `col`, later ones start at the indent.
		local offset = range.line == 1 and col or (continuation or col)
		highlights[#highlights + 1] = {
			line = line + range.line - 1,
			col = offset + range.col,
			end_col = offset + range.end_col,
			group = range.group,
		}
	end
	return highlights
end

--- Add a background range under already collected text highlights.
---@param highlights Crust.Chat.Tools.Highlight[]
---@param line integer
---@param col integer
---@param end_col integer
---@param group string
local function background(highlights, line, col, end_col, group)
	if end_col <= col then
		return
	end
	highlights[#highlights + 1] =
		{ line = line, col = col, end_col = end_col, group = group, priority = BACKGROUND_PRIORITY }
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
		head = head .. ":"
		highlights[#highlights].end_col = #head

		local prefix = self.spec.title_prefix or ""
		local prefix_col = #head + 1
		local col = prefix_col + #prefix
		head = head .. " " .. prefix .. title

		if prefix ~= "" then
			highlights[#highlights + 1] =
				{ line = 1, col = prefix_col, end_col = col, group = Highlights.TOOL_PREFIX }
		end

		local syntax = syntax_highlights(title, self.spec.title_lang, 1, col)
		if syntax then
			vim.list_extend(highlights, syntax)
		else
			highlights[#highlights + 1] = { line = 1, col = col, end_col = #head, group = Highlights.TOOL_TITLE }
		end
		-- Only the title text is shaded, not the icon and tool name.
		background(highlights, 1, prefix_col, #head, Highlights.TOOL_BACKGROUND)
	end

	local lines = { head }
	---@type table<integer, string>
	local line_highlights = {}

	if self:is_inline() then
		if #body > 0 then
			local col = #head + 1
			local text = table.concat(body, " ")
			lines[1] = head .. " " .. text
			local syntax = syntax_highlights(text, self.spec.body_lang, 1, col)
			if syntax then
				vim.list_extend(highlights, syntax)
			else
				highlights[#highlights + 1] =
					{ line = 1, col = col, end_col = #lines[1], group = Highlights.TOOL_BODY_INLINE }
			end
			-- Inline bodies share the title line, so only the text is shaded.
			background(highlights, 1, col, #lines[1], Highlights.TOOL_BODY_BACKGROUND)
		end
		return { lines = lines, highlights = highlights, line_highlights = line_highlights }
	end

	local body_prefix = self.spec.body_prefix or "  "
	local body_line = #lines + 1
	for _, line in ipairs(body) do
		lines[#lines + 1] = vim.trim(body_prefix .. line) == "" and body_prefix or (body_prefix .. line)
		-- Tool output gets a full-width line background.
		line_highlights[#lines] = Highlights.TOOL_BODY_BACKGROUND
		if self.spec.body_prefix then
			highlights[#highlights + 1] =
				{ line = #lines, col = 0, end_col = #body_prefix, group = Highlights.TOOL_PREFIX }
		end
	end

	local syntax = #body > 0
		and syntax_highlights(table.concat(body, "\n"), self.spec.body_lang, body_line, #body_prefix, #body_prefix)
	if syntax then
		vim.list_extend(highlights, syntax)
	else
		for index = body_line, #lines do
			highlights[#highlights + 1] =
				{ line = index, col = #body_prefix, end_col = #lines[index], group = Highlights.TOOL_BODY }
		end
	end

	return { lines = lines, highlights = highlights, line_highlights = line_highlights }
end

--- Rendered lines without highlight information.
---@return string[]
function Display:lines()
	return self:render().lines
end

return Display
