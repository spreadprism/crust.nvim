--- The bar along the bottom of the prompt: what the turn costs and which
--- model is answering.
---
--- It is not a 'statusline' and not a window: a single extmark on the last
--- line of the input buffer carries `virt_lines`, padded with blank rows so
--- the bar sits on the last row of the prompt window whatever is typed above
--- it. That keeps it out of 'laststatus', out of the window count, and out of
--- the way of the text.
---
--- The content is `config.input_bar.layout`: two lists of component names,
--- literal separators or functions, evaluated into highlighted chunks. Left
--- is drawn from the left edge, right is pushed against the right one.

---@class Crust.Chat.InputBar.State  what the components draw from
---@field model_id string? e.g. "claude-opus-4-6"
---@field model_name string? human name, when pi reports one
---@field model_provider string? e.g. "anthropic"
---@field context_window integer?
---@field reasoning boolean the model supports thinking levels
---@field thinking_level string?
---@field context_tokens integer? tokens of the last message, the context estimate
---@field input integer accumulated over the session
---@field output integer
---@field cache_read integer
---@field cache_write integer
---@field cost number in dollars

---@alias Crust.Chat.InputBar.Chunk { [1]: string, [2]: string? } text and highlight group
--- A component returns text (plus an optional group), a list of chunks, or
--- nil to hide itself — and with it the separators around it.
---@alias Crust.Chat.InputBar.Component fun(state: Crust.Chat.InputBar.State, opts: table): (string|Crust.Chat.InputBar.Chunk[]|nil), string?

---@class Crust.Chat.InputBar
---@field private _buf integer
---@field private _win fun(): integer?
---@field private _state Crust.Chat.InputBar.State
---@field private _extmark integer?
---@field private _rows integer virt_lines currently drawn, padding included
---@field private _augroup integer?
local InputBar = {}
InputBar.__index = InputBar

local Highlights = require("crust.ui.highlights")

InputBar.ns = vim.api.nvim_create_namespace("crust.chat.inputbar")

--- Columns kept free at the right edge.
local RIGHT_MARGIN = 1
--- Smallest gap between the two sides.
local MIN_GAP = 2

--- "3.8k", "7.2M": a token count nobody wants to read digit by digit.
---@param count integer
---@return string
local function tokens(count)
	if count < 1000 then
		return tostring(count)
	elseif count < 9950 then
		return string.format("%.1fk", count / 1000)
	elseif count < 1000000 then
		return string.format("%dk", math.floor(count / 1000 + 0.5))
	elseif count < 9950000 then
		return string.format("%.1fM", count / 1000000)
	end
	return string.format("%dM", math.floor(count / 1000000 + 0.5))
end

--- Pick the group a threshold pair asks for, nil for the plain one.
---@param value number
---@param opts table component options, `warn` and `error` are levels
---@return string?
local function threshold(value, opts)
	if type(opts.error) == "number" and value >= opts.error then
		return Highlights.INPUT_BAR_ERROR
	elseif type(opts.warn) == "number" and value >= opts.warn then
		return Highlights.INPUT_BAR_WARNING
	end
	return nil
end

--- Components available by name in `layout`.
---@type table<string, Crust.Chat.InputBar.Component>
InputBar.components = {}

--- `$0.123`, hidden until the session has cost something.
function InputBar.components.cost(state, opts)
	if state.cost <= 0 then
		return nil
	end
	return string.format("$%.3f", state.cost), threshold(state.cost, opts)
end

--- `claude-opus-4-6`.
function InputBar.components.model(state)
	return state.model_id
end

--- `↑3.8k ↓58k`, the tokens sent and received this session.
function InputBar.components.tokens(state)
	local parts = {}
	if state.input > 0 then
		parts[#parts + 1] = "↑" .. tokens(state.input)
	end
	if state.output > 0 then
		parts[#parts + 1] = "↓" .. tokens(state.output)
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

--- `R7.2M W416k`, the prompt cache.
function InputBar.components.cache(state)
	local parts = {}
	if state.cache_read > 0 then
		parts[#parts + 1] = "R" .. tokens(state.cache_read)
	end
	if state.cache_write > 0 then
		parts[#parts + 1] = "W" .. tokens(state.cache_write)
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

--- `63.9%/200k`, how full the context window is.
function InputBar.components.context(state, opts)
	if not state.context_window or state.context_window <= 0 then
		return nil
	end

	local window = tokens(state.context_window)
	if not state.context_tokens then
		return "-/" .. window
	end

	local percent = state.context_tokens / state.context_window * 100
	return string.format("%.1f%%/%s", percent, window), threshold(percent, opts)
end

--- `xhigh`, or `thinking off`, for models that reason.
function InputBar.components.thinking(state)
	if not state.reasoning or not state.thinking_level then
		return nil
	end
	if state.thinking_level == "off" then
		return "thinking off"
	end
	return state.thinking_level
end

---@return Crust.Chat.InputBar.State
local function empty_state()
	return {
		model_id = nil,
		model_name = nil,
		model_provider = nil,
		context_window = nil,
		reasoning = false,
		thinking_level = nil,
		context_tokens = nil,
		input = 0,
		output = 0,
		cache_read = 0,
		cache_write = 0,
		cost = 0,
	}
end

---@param buf integer input buffer
---@param win fun(): integer? the prompt window, read on every render
---@return Crust.Chat.InputBar
function InputBar.new(buf, win)
	local self = setmetatable({}, InputBar)

	Highlights.setup()
	self._buf = buf
	self._win = win
	self._state = empty_state()
	self._extmark = nil
	self._rows = 0
	self:_watch()
	self:render()

	return self
end

---@return Crust.Chat.InputBar.State
function InputBar:state()
	return self._state
end

--- Rows the bar occupies, padding included. The prompt subtracts them when
--- it measures its own content.
---@return integer
function InputBar:rows()
	return self._rows
end

---@private
---@return Crust.Config.InputBar
function InputBar:opts()
	return require("crust.config").get().input_bar
end

---@private
---@param name string
---@return table
function InputBar:component_opts(name)
	local components = self:opts().components or {}
	local opts = components[name]
	return type(opts) == "table" and opts or {}
end

--- Typing moves the last line the bar hangs on, and a resize changes the
--- padding that pins it to the bottom.
---@private
function InputBar:_watch()
	self._augroup = vim.api.nvim_create_augroup("crust.chat.inputbar." .. self._buf, { clear = true })

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = self._augroup,
		buffer = self._buf,
		callback = function()
			self:render()
		end,
	})

	vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "BufWinEnter" }, {
		group = self._augroup,
		callback = function()
			if self._win() then
				self:render()
			end
		end,
	})
end

--- Fold a `get_state` answer in: the model and how it thinks.
---@param data Crust.Pi.Data.State?
function InputBar:update_state(data)
	if not data then
		return
	end

	local model = data.model
	self._state.model_id = model and model.id or nil
	self._state.model_name = model and model.name or nil
	self._state.model_provider = model and model.provider or nil
	self._state.context_window = model and model.contextWindow or nil
	self._state.reasoning = model ~= nil and model.reasoning == true
	self._state.thinking_level = data.thinkingLevel

	self:render()
end

--- Add the usage of one assistant message.
---
--- Tokens and cost accumulate over the session; the context estimate does
--- not — the newest message carries the whole conversation, so it replaces
--- the previous figure instead of piling onto it.
---@param usage Crust.Pi.Usage?
function InputBar:add_usage(usage)
	-- A message that never reached the model reports nothing worth adding.
	if type(usage) ~= "table" or (usage.input or 0) <= 0 then
		return
	end

	local state = self._state
	state.input = state.input + (usage.input or 0)
	state.output = state.output + (usage.output or 0)
	state.cache_read = state.cache_read + (usage.cacheRead or 0)
	state.cache_write = state.cache_write + (usage.cacheWrite or 0)
	state.cost = state.cost + (type(usage.cost) == "table" and (usage.cost.total or 0) or 0)
	state.context_tokens = (usage.input or 0)
		+ (usage.output or 0)
		+ (usage.cacheRead or 0)
		+ (usage.cacheWrite or 0)

	self:render()
end

--- Forget the session totals, e.g. on a new session. The model is kept: it
--- is a property of the process, not of the conversation.
function InputBar:reset()
	local state = self._state
	state.input, state.output = 0, 0
	state.cache_read, state.cache_write = 0, 0
	state.cost = 0
	state.context_tokens = nil
	self:render()
end

--- Resolve a layout item, nil when it is a literal separator.
---@private
---@param item string|Crust.Chat.InputBar.Component
---@return Crust.Chat.InputBar.Component?, string? name of the built-in
function InputBar:_resolve(item)
	if type(item) == "function" then
		return item, nil
	end
	if type(item) == "string" and InputBar.components[item] then
		return InputBar.components[item], item
	end
	return nil, nil
end

--- Evaluate one side of the layout into chunks.
---
--- A hidden component takes the separators around it with it, so a layout
--- never renders a dangling `·`.
---@param items (string|Crust.Chat.InputBar.Component)[]
---@return Crust.Chat.InputBar.Chunk[] chunks
---@return integer width display cells
function InputBar:side(items)
	local chunks, width = {}, 0
	local pending = nil
	local drawn = false

	---@param text string
	---@param group string?
	local function push(text, group)
		if text == "" then
			return
		end
		chunks[#chunks + 1] = { text, group or Highlights.INPUT_BAR }
		width = width + vim.fn.strdisplaywidth(text)
	end

	for _, item in ipairs(items or {}) do
		local component, name = self:_resolve(item)
		if component then
			local ok, result, group = pcall(component, self._state, name and self:component_opts(name) or {})
			if ok and result ~= nil then
				if drawn then
					-- Components that follow each other are spaced by one
					-- column unless the layout asked for something else.
					push(pending or " ")
				end
				pending = nil

				if type(result) == "table" then
					for _, chunk in ipairs(result) do
						push(chunk[1], chunk[2])
					end
				else
					push((name and self:_icon(name) or "") .. result, group)
				end
				drawn = true
			else
				pending = nil
			end
		elseif type(item) == "string" and drawn then
			pending = item
		end
	end

	return chunks, width
end

--- The configured icon of a built-in, as a prefix.
---@private
---@param name string
---@return string
function InputBar:_icon(name)
	local icon = self:component_opts(name).icon
	if type(icon) ~= "string" or icon == "" then
		return ""
	end
	return icon .. " "
end

--- The bar as one row of chunks, the two sides pushed apart to `width`.
---@param width integer columns available
---@return Crust.Chat.InputBar.Chunk[]
function InputBar:line(width)
	local layout = self:opts().layout or {}
	local left, left_width = self:side(layout.left)
	local right, right_width = self:side(layout.right)

	-- The left side has priority: a narrow prompt cuts the model name, not
	-- the running cost.
	local available = width - left_width - MIN_GAP - RIGHT_MARGIN
	if right_width > available then
		local kept, used = {}, 0
		for _, chunk in ipairs(right) do
			local chunk_width = vim.fn.strdisplaywidth(chunk[1])
			if used + chunk_width <= available then
				kept[#kept + 1] = chunk
				used = used + chunk_width
			else
				local room = available - used
				if room > 0 then
					kept[#kept + 1] = { vim.fn.strcharpart(chunk[1], 0, room), chunk[2] }
					used = used + room
				end
				break
			end
		end
		right, right_width = kept, math.max(used, 0)
	end

	local chunks = {}
	vim.list_extend(chunks, left)
	if #right > 0 then
		local gap = math.max(MIN_GAP, width - left_width - right_width - RIGHT_MARGIN)
		chunks[#chunks + 1] = { string.rep(" ", gap), Highlights.INPUT_BAR }
	end
	vim.list_extend(chunks, right)

	return chunks
end

--- Text columns of the prompt window.
---@private
---@param win integer
---@return integer
local function text_width(win)
	local info = vim.fn.getwininfo(win)[1]
	if info then
		return math.max(info.width - info.textoff, 1)
	end
	return vim.api.nvim_win_get_width(win)
end

--- Blank rows between the typed text and the bar, so the bar sits on the
--- last row of the window. Measured with the bar off the buffer: its own
--- rows count towards the height nvim reports, and a rewrite of the buffer
--- drops the extmark without telling us.
---@private
---@param win integer
---@return integer
function InputBar:_padding(win)
	local height = vim.api.nvim_win_get_height(win) - (vim.wo[win].winbar ~= "" and 1 or 0)
	local drawn = vim.api.nvim_win_text_height(win, {}).all
	return math.max(height - drawn - 1, 0)
end

--- Draw the bar, or take it away when it is turned off.
function InputBar:render()
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	local opts = self:opts()
	local win = self._win()
	if not opts.enabled or not win then
		return self:clear()
	end

	local chunks = self:line(text_width(win))
	if #chunks == 0 then
		return self:clear()
	end

	-- Off the buffer first, so the window height below is the height of what
	-- the user typed and nothing else.
	self:clear()

	---@type Crust.Chat.InputBar.Chunk[][]
	local virt_lines = {}
	for _ = 1, self:_padding(win) do
		virt_lines[#virt_lines + 1] = { { "", "" } }
	end
	virt_lines[#virt_lines + 1] = chunks
	self._rows = #virt_lines

	local last = vim.api.nvim_buf_line_count(self._buf) - 1
	self._extmark = vim.api.nvim_buf_set_extmark(self._buf, InputBar.ns, last, 0, {
		id = self._extmark,
		virt_lines = virt_lines,
	})
end

--- Take the bar off the buffer, keeping the state it collected.
function InputBar:clear()
	self._rows = 0
	if self._extmark and vim.api.nvim_buf_is_valid(self._buf) then
		pcall(vim.api.nvim_buf_del_extmark, self._buf, InputBar.ns, self._extmark)
	end
	self._extmark = nil
end

function InputBar:close()
	if self._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
		self._augroup = nil
	end
	self:clear()
end

return InputBar
