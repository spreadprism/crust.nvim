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
---@field body_prefix? string extra indent before each body line, default none
---@field block_prefix? string written before every line of the call, default "> ", "" disables it

---@class Crust.Chat.Tools.Display
---@field name string tool name
---@field args table arguments of the call
---@field status Crust.Chat.Tools.Status
---@field result Crust.Pi.ToolResult? set when the call ends
---@field spec Crust.Chat.Tools.Spec
local Display = {}
Display.__index = Display

--- Every tool call is rendered as a quoted block.
Display.BLOCK_PREFIX = "> "

local Config = require("crust.config")
local Highlights = require("crust.ui.highlights")
local Syntax = require("crust.ui.syntax")

---@class Crust.Chat.Tools.Highlight
---@field line integer 1-based index into the rendered lines
---@field col integer byte offset, 0-based
---@field end_col integer byte offset, exclusive
---@field group string highlight group
---@field overlay? string text drawn over the range, e.g. the quote marker

---@class Crust.Chat.Tools.Render
---@field lines string[]
---@field highlights Crust.Chat.Tools.Highlight[]
---@field line_highlights table<integer, string> full-line background per line

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

--- Cut a line to `width` display cells, marking the cut with an ellipsis.
---@param line string
---@param width integer
---@return string
local function truncate(line, width)
	if width < 2 or vim.fn.strdisplaywidth(line) <= width then
		return line
	end

	local chars = vim.fn.strchars(line)
	for count = chars, 0, -1 do
		local cut = vim.fn.strcharpart(line, 0, count)
		if vim.fn.strdisplaywidth(cut) + 1 <= width then
			return cut .. "…"
		end
	end

	return line
end

--- Keep the title on one line: cut it and clamp the highlights that ran past
--- the cut, so a long command never wraps.
---@private
---@param render Crust.Chat.Tools.Render
---@param width integer?
---@return Crust.Chat.Tools.Render
function Display:_truncate_title(render, width)
	if not width or width <= 0 then
		return render
	end

	local line = render.lines[1]
	local cut = truncate(line, width)
	if cut == line then
		return render
	end
	render.lines[1] = cut

	local limit = #cut
	local kept = {}
	for _, hl in ipairs(render.highlights) do
		if hl.line ~= 1 or hl.col < limit then
			if hl.line == 1 then
				hl.end_col = math.min(hl.end_col, limit)
			end
			kept[#kept + 1] = hl
		end
	end
	render.highlights = kept

	return render
end

--- Lines plus their highlight ranges.
---@param width integer? cut the title line to this many cells
---@return Crust.Chat.Tools.Render
function Display:render(width)
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
	end

	local lines = { head }
	-- The whole call is one shaded block.
	---@type table<integer, string>
	local line_highlights = { Highlights.TOOL_BACKGROUND }

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
		end
		return self:_truncate_title(
			self:_prefix_block({ lines = lines, highlights = highlights, line_highlights = line_highlights }),
			width
		)
	end

	local body_prefix = self.spec.body_prefix or ""
	local body_line = #lines + 1
	for _, line in ipairs(body) do
		lines[#lines + 1] = vim.trim(body_prefix .. line) == "" and body_prefix or (body_prefix .. line)
		line_highlights[#lines] = Highlights.TOOL_BODY_BACKGROUND
		if self.spec.body_prefix and body_prefix ~= "" then
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

	return self:_truncate_title(
		self:_prefix_block({ lines = lines, highlights = highlights, line_highlights = line_highlights }),
		width
	)
end

--- Put `block_prefix` in front of every line and shift the highlights along.
---@private
---@param render Crust.Chat.Tools.Render
---@return Crust.Chat.Tools.Render
function Display:_prefix_block(render)
	local prefix = self.spec.block_prefix or Display.BLOCK_PREFIX
	if prefix == "" then
		return render
	end

	-- Shift the existing highlights before adding the prefix ones.
	for _, hl in ipairs(render.highlights) do
		hl.col = hl.col + #prefix
		hl.end_col = hl.end_col + #prefix
	end

	-- The block is kept out of the markdown tree, so the quote marker that
	-- render-markdown would draw for "> " is drawn here instead.
	local icon = Config.get().icons.quote
	local overlay = icon and icon ~= "" and (icon .. string.rep(" ", math.max(#prefix - #icon, 0))) or nil

	for index, line in ipairs(render.lines) do
		render.lines[index] = vim.trim(line) == "" and prefix or (prefix .. line)
		render.highlights[#render.highlights + 1] = {
			line = index,
			col = 0,
			end_col = #prefix,
			group = Highlights.TOOL_PREFIX,
			overlay = overlay,
		}
	end

	return render
end

--- Rendered lines without highlight information.
---@param width integer?
---@return string[]
function Display:lines(width)
	return self:render(width).lines
end

return Display
