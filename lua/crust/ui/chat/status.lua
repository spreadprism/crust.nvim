--- Busy status rendered under the last line of the output buffer.
---
--- Like pi.nvim, this is a `virt_lines` extmark on the last line, not real
--- buffer text: nothing has to be deleted when the agent stops, and the
--- transcript stays clean. A uv timer advances the spinner frame.

---@class Crust.Chat.Status
---@field private _output Crust.Chat.Output
---@field private _text string?
---@field private _frames string[]
---@field private _rate integer
---@field private _index integer
---@field private _timer uv.uv_timer_t?
---@field private _started_at integer? seconds
---@field private _extmark integer?
local Status = {}
Status.__index = Status

local Highlights = require("crust.ui.highlights")

local ns = vim.api.nvim_create_namespace("crust.chat.status")

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
	self._extmark = nil
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

--- Show `text` with a spinner, or clear the status when `text` is nil.
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

--- Spinner frame plus text, as it appears in the buffer. The text is
--- optional, an empty one leaves just the animated icon.
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

--- "<C-c> to cancel", empty when no cancel key is bound.
---@return string
function Status:hint()
	local key = require("crust.config").get().keymaps.cancel
	if not key or key == "" then
		return ""
	end
	return "  " .. key .. " to cancel"
end

--- Draw, move, or remove the status extmark.
function Status:render()
	local buf = self._output:buf()
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	if self._extmark then
		vim.api.nvim_buf_del_extmark(buf, ns, self._extmark)
		self._extmark = nil
	end

	if not self._text then
		return
	end

	local icon = self._frames[self._index]
	local text = self._text ~= "" and ("  " .. self._text) or ""
	local elapsed = self:elapsed()
	local hint = self:hint()

	-- Centered on the output window, like pi.nvim.
	local width = self._output:width()
	local pad = 0
	if width then
		pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(icon .. text .. elapsed .. hint)) / 2))
	end

	local last_line = vim.api.nvim_buf_line_count(buf) - 1
	self._extmark = vim.api.nvim_buf_set_extmark(buf, ns, last_line, 0, {
		virt_lines = {
			{ { "" } },
			{
				{ string.rep(" ", pad) .. icon, Highlights.STATUS_ICON },
				{ text, Highlights.STATUS },
				{ elapsed, Highlights.STATUS_TIME },
				{ hint, Highlights.STATUS_HINT },
			},
			{ { "" } },
		},
	})

	self._output:follow()
end

function Status:close()
	self:_stop_timer()
	self._text = nil
	self:render()
end

return Status
