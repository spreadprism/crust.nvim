--- Tool call rendering for the chat output panel.
---
--- Every tool call gets a `Crust.Chat.Tools.Display` built from a spec.
--- `Tools.DEFAULT` is used unless a tool-specific spec is registered below;
--- per-tool specs live in `crust/ui/chat/tools/<tool>.lua`.

---@class Crust.Chat.Tools
---@field private _displays table<string, Crust.Chat.Tools.Display>
---@field private _blocks table<string, Crust.Chat.Output.Block>
local Tools = {}
Tools.__index = Tools

local Display = require("crust.ui.chat.tools.display")

---@type table<string, true>
local HANDLED = {
	tool_execution_start = true,
	tool_execution_update = true,
	tool_execution_end = true,
}

--- Arguments most worth showing when a tool has no dedicated spec.
local SUMMARY_KEYS = { "command", "path", "file_path", "pattern", "query", "url" }

--- Fallback display: the tool's most telling argument.
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
		if display.status == "error" then
			return display:result_text()
		end
		return nil
	end,
}

---@type table<string, Crust.Chat.Tools.Spec>
Tools.registry = {
	bash = require("crust.ui.chat.tools.bash"),
	read = require("crust.ui.chat.tools.read"),
}

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
	return self
end

---@param id string
---@return Crust.Chat.Tools.Display?
function Tools:display(id)
	return self._displays[id]
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
		display = Display.new(name, Tools.spec(name), event.args)
		self._displays[id] = display
	end
	display:update(event)

	local render = display:render()
	local block = self._blocks[id]
	if block then
		output:replace_block(block, render.lines, render.highlights)
	else
		self._blocks[id] = output:append_block(render.lines, render.highlights)
	end
end

function Tools:reset()
	self._displays = {}
	self._blocks = {}
end

return Tools
