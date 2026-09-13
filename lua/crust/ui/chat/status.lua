--- Status bar: the output window's own statusline.
---
--- Left side is the spinner and the elapsed time, right side is the cancel
--- hint. Nothing is written to the buffer and no extra window is created.

---@class Crust.Chat.Status
---@field private _output Crust.Chat.Output
---@field private _text string?
---@field private _frames string[]
---@field private _rate integer
---@field private _index integer
---@field private _timer uv.uv_timer_t?
---@field private _started_at integer? seconds
local Status = {}
Status.__index = Status

local Highlights = require("crust.ui.highlights")

---@class Crust.Spinner
---@field refresh_rate integer ms between frames
---@field frames string[]

---@type table<string, Crust.Spinner>
Status.presets = {
	classic = {
		refresh_rate = 80,
		frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
	},
	robot = {
		refresh_rate = 300,
		frames = {
			"󰚩",
			"󱙺",
			"󱚝",
			"󱚞",
			"󱚟",
			"󱚠",
			"󱚡",
			"󱚢",
			"󱚣",
			"󱚤",
			"󱚟",
			"󱚠",
			"󱜙",
			"󱜚",
			"󱚥",
			"󱚦",
		},
	},
	dots = {
		refresh_rate = 250,
		frames = { "·", "․", "•", "∙", "●", "∙", "•", "․" },
	},
}

--- Resolve the configured spinner: a preset name or a custom definition.
---@param opt string|string[]|Crust.Spinner
---@return Crust.Spinner
function Status.spinner(opt)
	if type(opt) == "table" then
		return {
			refresh_rate = opt.refresh_rate or Status.presets.classic.refresh_rate,
			frames = opt.frames or opt,
		}
	end
	return Status.presets[opt] or Status.presets.robot
end

---@param output Crust.Chat.Output
---@return Crust.Chat.Status
function Status.new(output)
	local self = setmetatable({}, Status)
	self._output = output
	self._text = nil
	self._index = 1
	self._timer = nil
	self:_pick_spinner()
	return self
end

---@private
function Status:_pick_spinner()
	local spinner = Status.spinner(require("crust.config").get().spinner)
	self._frames = spinner.frames
	self._rate = spinner.refresh_rate
end

---@return string?
function Status:text()
	return self._text
end

---@return boolean
function Status:is_running()
	return self._timer ~= nil
end

--- Show `text` with a spinner, or clear the bar when `text` is nil.
---@param text string?
function Status:set(text)
	if text == self._text then
		return
	end

	self._text = text
	self._index = 1
	self._started_at = text and math.floor(vim.uv.hrtime() / 1e9) or nil

	self:_stop_timer()
	-- The spinner may have been reconfigured since the last run.
	self:_pick_spinner()
	self:render()

	if not text then
		return
	end

	self._timer = assert(vim.uv.new_timer())
	self._timer:start(
		self._rate,
		self._rate,
		vim.schedule_wrap(function()
			if not self._text then
				return
			end
			self._index = self._index % #self._frames + 1
			self:render()
		end)
	)
end

function Status:clear()
	self:set(nil)
end

---@private
function Status:_stop_timer()
	if self._timer then
		self._timer:stop()
		self._timer:close()
		self._timer = nil
	end
end

--- Elapsed time since the status was set, e.g. " for 1m 4s".
---@return string
function Status:elapsed()
	if not self._started_at then
		return ""
	end

	local secs = math.floor(vim.uv.hrtime() / 1e9) - self._started_at
	if secs >= 60 then
		return " for " .. math.floor(secs / 60) .. "m " .. (secs % 60) .. "s"
	elseif secs >= 1 then
		return " for " .. secs .. "s"
	end
	return ""
end

--- Left side: spinner frame, then the optional status text.
---@return string
function Status:line()
	if not self._text then
		return ""
	end
	local frame = self._frames[self._index]
	if self._text == "" then
		return frame
	end
	return frame .. "  " .. self._text
end

--- Right side: "<C-c> to cancel", empty when no cancel key is bound.
---@return string
function Status:hint()
	local key = require("crust.config").get().keymaps.cancel
	if not key or key == "" then
		return ""
	end
	return key .. " to cancel"
end

--- The 'statusline' value for the output window. Empty when idle.
---@return string
function Status:statusline()
	if not self._text then
		return ""
	end

	local left = "%#" .. Highlights.STATUS_ICON .. "# " .. self._frames[self._index]
	if self._text ~= "" then
		left = left .. "%#" .. Highlights.STATUS .. "#  " .. self._text
	end
	left = left .. "%#" .. Highlights.STATUS_TIME .. "#" .. self:elapsed()

	local hint = self:hint()
	local right = hint ~= "" and ("%#" .. Highlights.STATUS_HINT .. "#" .. hint .. " ") or ""

	return left .. "%#" .. Highlights.STATUS .. "#%=" .. right
end

--- Push the statusline onto the output window.
function Status:render()
	local win = self._output:win()
	if not win then
		return
	end

	vim.wo[win].statusline = self:statusline()
	vim.cmd("redrawstatus")
end

function Status:close()
	self:_stop_timer()
	self._text = nil

	local win = self._output:win()
	if win then
		vim.wo[win].statusline = ""
	end
end

return Status
