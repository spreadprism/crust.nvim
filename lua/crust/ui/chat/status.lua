--- Status bar floating over the last row of the output window.
---
--- Like opencode.nvim's footer, this is a `relative = "win"` float anchored
--- SW on the output window, not a split and not a statusline: it works
--- whatever 'laststatus' is set to. Left side is the spinner and the elapsed
--- time, right side is the cancel hint.

---@class Crust.Chat.Status
---@field private _output Crust.Chat.Output
---@field private _buf integer
---@field private _win integer?
---@field private _text string?
---@field private _frames string[]
---@field private _rate integer
---@field private _index integer
---@field private _timer uv.uv_timer_t?
---@field private _started_at integer? seconds
local Status = {}
Status.__index = Status

local Highlights = require("crust.ui.highlights")
local scratch = require("crust.ui.scratch")

local ns = vim.api.nvim_create_namespace("crust.chat.status")

Status.HEIGHT = 1
Status.FILETYPE = "crust_status"

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
	self._buf = scratch("crust://status", Status.FILETYPE)
	vim.bo[self._buf].modifiable = false
	self._win = nil
	self._text = nil
	self._index = 1
	self._timer = nil
	self:_pick_spinner()
	return self
end

---@return integer
function Status:buf()
	return self._buf
end

---@return integer?
function Status:win()
	if self._win and vim.api.nvim_win_is_valid(self._win) then
		return self._win
	end
	return nil
end

--- Float covering the bottom row of the output window.
---@private
---@param output_win integer
---@return vim.api.keyset.win_config
function Status:_win_config(output_win)
	return {
		relative = "win",
		win = output_win,
		anchor = "SW",
		width = vim.api.nvim_win_get_width(output_win),
		height = Status.HEIGHT,
		row = vim.api.nvim_win_get_height(output_win),
		col = 0,
		focusable = false,
		style = "minimal",
		border = "none",
		zindex = 50,
	}
end

---@private
function Status:_open()
	local output_win = self._output:win()
	if not output_win or self:win() then
		return
	end

	self._win = vim.api.nvim_open_win(self._buf, false, self:_win_config(output_win))
	vim.wo[self._win].winhighlight = "Normal:" .. Highlights.STATUS
end

---@private
function Status:_close_win()
	local win = self:win()
	if win then
		vim.api.nvim_win_close(win, true)
	end
	self._win = nil
end

--- Follow the output window when it moves or resizes.
function Status:update_window()
	local output_win = self._output:win()
	local win = self:win()
	if not output_win or not win then
		return
	end

	vim.api.nvim_win_set_config(win, self:_win_config(output_win))
	self:render()
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

--- Elapsed time since the status was set, e.g. "  for 1m 4s". Shown from
--- the first render on, so the counter never pops in late.
---@return string
function Status:elapsed()
	if not self._started_at then
		return ""
	end

	local secs = math.floor(vim.uv.hrtime() / 1e9) - self._started_at
	if secs >= 60 then
		return "  for " .. math.floor(secs / 60) .. "m " .. (secs % 60) .. "s"
	end
	return "  for " .. math.max(secs, 0) .. "s"
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

--- Highlighted segments of the bar, left side then right side.
---@return { text: string, group: string }[] left
---@return { text: string, group: string }[] right
function Status:segments()
	if not self._text then
		return {}, {}
	end

	local left = { { text = " " .. self._frames[self._index], group = Highlights.STATUS_ICON } }
	if self._text ~= "" then
		left[#left + 1] = { text = "  " .. self._text, group = Highlights.STATUS }
	end

	local elapsed = self:elapsed()
	if elapsed ~= "" then
		left[#left + 1] = { text = elapsed, group = Highlights.STATUS_TIME }
	end

	local right = {}
	local hint = self:hint()
	if hint ~= "" then
		right[#right + 1] = { text = hint .. " ", group = Highlights.STATUS_HINT }
	end

	return left, right
end

--- The bar as one line, left and right pushed apart to `width`.
---@param width integer
---@return string line
---@return { group: string, col: integer, end_col: integer }[] highlights
function Status:line_for(width)
	local left, right = self:segments()

	local parts, highlights, col = {}, {}, 0
	local function add(segments)
		for _, segment in ipairs(segments) do
			parts[#parts + 1] = segment.text
			highlights[#highlights + 1] = { group = segment.group, col = col, end_col = col + #segment.text }
			col = col + #segment.text
		end
	end

	add(left)

	local used = 0
	for _, segment in ipairs(left) do
		used = used + vim.fn.strdisplaywidth(segment.text)
	end
	for _, segment in ipairs(right) do
		used = used + vim.fn.strdisplaywidth(segment.text)
	end

	local padding = string.rep(" ", math.max(0, width - used))
	parts[#parts + 1] = padding
	col = col + #padding

	add(right)

	return table.concat(parts), highlights
end

--- Draw the bar, opening or closing the float as the status comes and goes.
function Status:render()
	if not self._text then
		self:_close_win()
		return
	end

	self:_open()
	local win = self:win()
	if not win then
		return
	end

	local line, highlights = self:line_for(vim.api.nvim_win_get_width(win))

	vim.bo[self._buf].modifiable = true
	vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { line })
	vim.bo[self._buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(self._buf, ns, 0, -1)
	for _, hl in ipairs(highlights) do
		if hl.col < hl.end_col and hl.end_col <= #line then
			vim.api.nvim_buf_set_extmark(self._buf, ns, 0, hl.col, {
				end_col = hl.end_col,
				hl_group = hl.group,
			})
		end
	end
end

function Status:close()
	self:_stop_timer()
	self._text = nil
	self:_close_win()
end

return Status
