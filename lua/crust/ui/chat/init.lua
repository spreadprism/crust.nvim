--- Minimal chat: wires the pi process to an Input and an Output panel.

---@class Crust.Chat
---@field private _pi Crust.Pi
---@field private _input Crust.Chat.Input
---@field private _output Crust.Chat.Output
---@field private _tools Crust.Chat.Tools
---@field private _streaming boolean
---@field private _augroup integer?
---@field private _closing boolean
local Chat = {}
Chat.__index = Chat

local next_id = 0

local Pi = require("crust.pi.client")
local Command = require("crust.pi.rpc")
local Input = require("crust.ui.chat.input")
local Output = require("crust.ui.chat.output")
local Tools = require("crust.ui.chat.tools")
local Highlights = require("crust.ui.highlights")

local WIDTH_RATIO = 0.4

---@param opts? Crust.Pi.Opts
---@return Crust.Chat
function Chat.new(opts)
	local self = setmetatable({}, Chat)

	next_id = next_id + 1
	self._id = next_id
	self._closing = false
	self._streaming = false
	self._output = Output.new()
	self._tools = Tools.new()
	self._input = Input.new(function(text)
		self:_send(text)
	end)

	self._pi = Pi.new(vim.tbl_extend("force", opts or {}, {
		on_event = function(event)
			vim.schedule(function()
				self:_on_event(event)
			end)
		end,
	}))

	return self
end

---@return Crust.Pi
function Chat:pi()
	return self._pi
end

---@return Crust.Chat.Input
function Chat:input()
	return self._input
end

---@return Crust.Chat.Output
function Chat:output()
	return self._output
end

---@return integer out_buf, integer in_buf
function Chat:bufs()
	return self._output:buf(), self._input:buf()
end

---@return boolean
function Chat:is_visible()
	return self._output:win() ~= nil
end

function Chat:open()
	if self:is_visible() then
		self._input:focus()
		return
	end

	self._output:open(math.floor(vim.o.columns * WIDTH_RATIO))
	self._input:open()
	self:_watch_windows()

	local ok, err = self._pi:connect()
	if not ok then
		self._output:error(tostring(err))
	end

	self._input:focus()
end

--- Closing one panel closes the other: the two windows are one unit.
---@private
function Chat:_watch_windows()
	local watched = { [self._output:win()] = true, [self._input:win()] = true }

	self._augroup = vim.api.nvim_create_augroup("crust.chat." .. self._id, { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = self._augroup,
		callback = function()
			self:resize()
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = self._augroup,
		callback = function(event)
			if not watched[tonumber(event.match)] then
				return
			end
			-- WinClosed fires before the window is gone, so close the sibling
			-- once neovim is done tearing this one down.
			vim.schedule(function()
				self:close()
			end)
		end,
	})
end

--- Give the width change to the output panel and keep the input at its
--- fixed height.
function Chat:resize()
	if not self:is_visible() then
		return
	end

	self._output:set_width(math.floor(vim.o.columns * WIDTH_RATIO))
	self._input:restore_height()
end

function Chat:close()
	if self._closing then
		return
	end
	self._closing = true

	if self._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
		self._augroup = nil
	end

	self._input:close()
	self._output:close()
	self._closing = false
end

function Chat:toggle()
	if self:is_visible() then
		self:close()
	else
		self:open()
	end
end

function Chat:focus_input()
	self._input:focus()
end

--- Send the input buffer content as a prompt.
function Chat:submit()
	self._input:submit()
end

---@private
---@param text string
function Chat:_send(text)
	if not self._pi:is_running() then
		local ok, err = self._pi:connect()
		if not ok then
			self._output:error(tostring(err))
			return
		end
	end

	self._input:clear()
	self._output:header(require("crust.config").get().labels.user, Highlights.USER_TITLE)
	self._output:append(text .. "\n")

	local _, err = self._pi:send(
		Command.prompt(text, self._streaming and { streaming_behavior = "followUp" } or nil),
		function(event)
			if event.success == false then
				self._output:error(event.error or "prompt failed")
			end
		end
	)
	if err then
		self._output:error(err)
	end
end

function Chat:stop()
	self._pi:close()
end

---@private
---@param event Crust.Pi.Event
function Chat:_on_event(event)
	if event.type == "agent_start" then
		self._streaming = true
		self._output:header(require("crust.config").get().labels.agent, Highlights.AGENT_TITLE)
	elseif event.type == "agent_end" then
		self._streaming = false
		self._output:append("\n")
	elseif event.type == "message_update" then
		local ev = event.assistantMessageEvent
		if ev and ev.type == "text_delta" and ev.delta then
			self._output:append(ev.delta)
		end
	elseif Tools.handles(event.type) then
		self._tools:render(self._output, event)
	elseif event.type == "_stderr" then
		self._output:error(tostring(event.message))
	elseif event.type == "_process_exit" then
		self._streaming = false
		self._output:error("pi exited (" .. tostring(event.code) .. ")")
	end
end

return Chat
