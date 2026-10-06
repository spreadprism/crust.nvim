--- Tool call rendering for the chat output panel.
---
--- Every tool call gets a `Crust.Chat.Tools.Display` built from a spec.
--- `Tools.DEFAULT` is used unless a tool-specific spec is registered below;
--- per-tool specs live in `crust/ui/chat/tools/<tool>.lua`.

---@class Crust.Chat.Tools
---@field private _displays table<string, Crust.Chat.Tools.Display>
---@field private _blocks table<string, Crust.Chat.Output.Block>
---@field private _by_block table<integer, Crust.Chat.Tools.Display> block id -> call, for the cursor lookup
---@field private _last { block: Crust.Chat.Output.Block, inline: boolean }?
local Tools = {}
Tools.__index = Tools

local Display = require("crust.ui.chat.tools.display")
local Excerpt = require("crust.ui.chat.tools.excerpt")
local Preview = require("crust.ui.chat.tools.preview")

---@type table<string, true>
local HANDLED = {
	tool_execution_start = true,
	tool_execution_update = true,
	tool_execution_end = true,
}

--- Arguments most worth showing when a tool has no dedicated spec.
local SUMMARY_KEYS = { "command", "path", "file_path", "pattern", "query", "url" }

--- Fallback display: the tool's most telling argument, and what it answered.
--- A tool without a spec of its own still shows its result, cut to the first
--- `Excerpt.MAX_LINES` lines: the top of an answer is the part that says what
--- the call did.
---@type Crust.Chat.Tools.Spec
Tools.DEFAULT = {
	title = function(display)
		for _, key in ipairs(SUMMARY_KEYS) do
			local value = display.args[key]
			if type(value) == "string" and value ~= "" then
				return (value:gsub("%s+", " "))
			end
		end
		return ""
	end,
	body = function(display)
		-- A failure is short and worth reading whole.
		if display.status == "error" then
			return display:result_text()
		end

		local text = display:result_text()
		if not text or vim.trim(text) == "" then
			return nil
		end
		return (Excerpt.of(display, { from = "head" }))
	end,
	body_highlights = function(display)
		if display.status == "error" then
			return nil
		end
		local _, ranges = Excerpt.of(display, { from = "head" })
		return ranges
	end,
}

---@type table<string, Crust.Chat.Tools.Spec>
Tools.registry = {
	bash = require("crust.ui.chat.tools.bash"),
	read = require("crust.ui.chat.tools.read"),
	edit = require("crust.ui.chat.tools.edit"),
	write = require("crust.ui.chat.tools.write"),
	skill = require("crust.ui.chat.tools.skill"),
}

--- Pi has no skill event: a skill is loaded by reading its `SKILL.md`, and a
--- `/skill:name` command is expanded into the prompt before it is sent. So a
--- read of a skill file is shown as a skill load rather than as a plain read.
---@param name string tool name reported by pi
---@param args table?
---@return boolean
local function is_skill_load(name, args)
	if name ~= "read" or type(args) ~= "table" then
		return false
	end

	local path = args.path or args.file_path
	if type(path) ~= "string" then
		return false
	end

	path = path:gsub("\\", "/")
	if path:lower():match("/skill%.md$") then
		return true
	end
	return path:match("/skills/[^/]+%.md$") ~= nil
end

--- Register or override the spec used for a tool.
---@param name string
---@param spec Crust.Chat.Tools.Spec
function Tools.register(name, spec)
	Tools.registry[name] = spec
end

---@param name string
---@return Crust.Chat.Tools.Spec
function Tools.spec(name)
	return Tools.registry[name] or Tools.DEFAULT
end

--- True when `Tools:render` knows how to display this event type.
---@param event_type string
---@return boolean
function Tools.handles(event_type)
	return HANDLED[event_type] == true
end

---@return Crust.Chat.Tools
function Tools.new()
	local self = setmetatable({}, Tools)
	self._displays = {}
	self._blocks = {}
	self._by_block = {}
	self._last = nil
	return self
end

---@param id string
---@return Crust.Chat.Tools.Display?
function Tools:display(id)
	return self._displays[id]
end

--- The call a rendered block belongs to, e.g. the one under the cursor.
---@param block Crust.Chat.Output.Block?
---@return Crust.Chat.Tools.Display?
function Tools:display_at(block)
	return block and self._by_block[block.id] or nil
end

--- Write or rewrite the tool call block in the output panel.
---@param output Crust.Chat.Output
---@param event Crust.Pi.Event
function Tools:render(output, event)
	local id = event.toolCallId or event.id
	if not id then
		return
	end

	local display = self._displays[id]
	if not display then
		local name = event.toolName or "tool"
		if is_skill_load(name, event.args) then
			name = "skill"
		end
		display = Display.new(name, Tools.spec(name), event.args)
		self._displays[id] = display
	end
	display:update(event)

	-- A float open on this call follows it live, output and status alike.
	Preview.refresh(display)

	-- The title is cut to the window so a long command never wraps.
	local render = display:render(output:width())
	local block = self._blocks[id]
	if block then
		output:replace_block(block, render.lines, render.highlights, render.line_highlights)
		-- A call can stop being inline, e.g. when it fails.
		if self._last and self._last.block == block then
			self._last.inline = display:is_inline()
		end
		return
	end

	-- Inline calls that follow each other are stacked without a gap.
	local compact = display:is_inline()
		and self._last ~= nil
		and self._last.inline
		and output:block_ends_buffer(self._last.block)

	block = output:append_block(render.lines, render.highlights, render.line_highlights, compact)
	self._blocks[id] = block
	self._by_block[block.id] = display
	self._last = { block = block, inline = display:is_inline() }
end

--- Resolve every call still marked pending, e.g. when the turn ends without
--- pi reporting the end of a tool it never got to finish. Without this a
--- killed or timed out call keeps spinning in the scrollback forever.
---@param output Crust.Chat.Output
---@param status Crust.Chat.Tools.Status what the unfinished calls become
---@return integer settled number of calls that were still pending
function Tools:settle(output, status)
	local settled = 0
	for id, display in pairs(self._displays) do
		if display.status == "pending" then
			display:set_status(status)
			settled = settled + 1

			local block = self._blocks[id]
			if block then
				local render = display:render(output:width())
				output:replace_block(block, render.lines, render.highlights, render.line_highlights)
			end
			Preview.refresh(display)
		end
	end
	return settled
end

function Tools:reset()
	self._displays = {}
	self._blocks = {}
	self._by_block = {}
	self._last = nil
end

return Tools
