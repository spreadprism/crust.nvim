--- Chat output: the read-only scrollback window.
---
--- The conversation lives in a `Crust.Chat.Transcript`, not in the buffer.
--- The buffer only shows the sections around the one the user is looking at
--- (`Crust.Chat.Viewport`), so a thousand-message session costs the same as a
--- ten-message one: writes are section local and the markdown machinery only
--- ever sees what is on screen.

---@class Crust.Chat.Output
---@field private _buf integer
---@field private _win integer?
---@field private _transcript Crust.Chat.Transcript
---@field private _view Crust.Chat.Viewport
---@field private _title string?
---@field private _regions_timer uv.uv_timer_t?
---@field private _following boolean the view sticks to the newest message
---@field private _busy boolean a redraw is moving the cursor, ignore the autocmds
---@field private _batch boolean model-only writes, e.g. while a session replays
---@field private _augroup integer?
local Output = {}
Output.__index = Output

Output.FILETYPE = require("crust.filetypes").output

local scratch = require("crust.ui.scratch")
local Highlights = require("crust.ui.highlights")
local RenderMarkdown = require("crust.integrations.render_markdown")
local Regions = require("crust.ui.regions")
local Transcript = require("crust.ui.chat.transcript")
local Viewport = require("crust.ui.chat.viewport")

Output.SEPARATOR = Transcript.SEPARATOR

--- Quiet period before the markdown regions are recomputed.
local REGIONS_DEBOUNCE_MS = 50

---@return Crust.Chat.Viewport.Opts
local function view_opts()
	return require("crust.config").get().output.viewport
end

---@return Crust.Chat.Output
function Output.new()
	local self = setmetatable({}, Output)

	Highlights.setup()
	self._buf = scratch("crust://chat", Output.FILETYPE, true)
	self._transcript = Transcript.new()
	self._view = Viewport.new(self._buf, self._transcript, view_opts)
	self._following = true
	self._busy = false
	self._batch = false
	vim.bo[self._buf].modifiable = false
	self._win = nil

	self._view:rebuild()

	return self
end

---@return integer
function Output:buf()
	return self._buf
end

---@return integer?
function Output:win()
	if self._win and vim.api.nvim_win_is_valid(self._win) then
		return self._win
	end
	return nil
end

---@return Crust.Chat.Transcript
function Output:transcript()
	return self._transcript
end

---@return Crust.Chat.Viewport
function Output:view()
	return self._view
end

--- Open the output window as a right-hand vertical split.
---@param width integer
function Output:open(width)
	if self:win() then
		return
	end

	vim.cmd("botright " .. width .. "vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, self._buf)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixwidth = true
	vim.wo[win].winfixbuf = true
	self._win = win
	self:_watch_scroll()
	-- The window is new, so the remembered title has to be drawn again.
	self:set_title(self._title)
end

--- Show `title` centered in the window bar, e.g. the session name.
---@param title string? nil or "" removes the bar
function Output:set_title(title)
	self._title = title

	local win = self:win()
	if not win then
		return
	end

	if not title or title == "" then
		vim.wo[win].winbar = ""
		return
	end

	-- Session names are user text, so `%` items have to be escaped.
	local text = title:gsub("%%", "%%%%")
	vim.wo[win].winbar = table.concat({
		"%#" .. Highlights.WINBAR .. "#%=",
		"%#" .. Highlights.WINBAR_TITLE .. "# " .. text .. " ",
		"%#" .. Highlights.WINBAR .. "#%=",
	})
end

---@return string?
function Output:title()
	return self._title
end

--- Resize the output window, the panel owns the remaining space.
---@param width integer
function Output:set_width(width)
	local win = self:win()
	if win then
		vim.api.nvim_win_set_width(win, math.max(width, 1))
	end
end

function Output:close()
	local win = self:win()
	if win then
		vim.api.nvim_win_close(win, false)
	end
	self._win = nil
	RenderMarkdown.detach(self._buf)

	if self._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
		self._augroup = nil
	end

	if self._regions_timer then
		self._regions_timer:stop()
		self._regions_timer:close()
		self._regions_timer = nil
	end
end

--- Text columns available in the output window, nil when it is not shown.
---@return integer?
function Output:width()
	local win = self:win()
	if not win then
		return nil
	end

	local info = vim.fn.getwininfo(win)[1]
	local width = info and info.width or vim.api.nvim_win_get_width(win)
	local textoff = info and info.textoff or 0
	return math.max(width - textoff, 1)
end

--- Collect a whole conversation without drawing it, then draw once.
--- Replaying a session through the normal path would redraw per message.
---@param fn fun()
function Output:batch(fn)
	local was = self._batch
	self._batch = true

	local ok, err = pcall(fn)

	self._batch = was
	if not self._batch then
		self._view:rebuild()
		self:_refresh_regions()
		self:_render_markdown()
	end

	if not ok then
		error(err)
	end
end

--- Append raw text, continuing the last line (streaming friendly).
---@param text string
function Output:append(text)
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	local patch = self._transcript:append(text)
	if self._batch or not self._view:patch(patch) then
		return
	end

	self:_follow()
	self:_render_markdown()
end

--- Append lines as a rewritable block, isolated by one blank line on each
--- side so streamed text never reads as part of the block.
---@param lines string[]
---@param highlights? Crust.Chat.Tools.Highlight[]
---@param line_highlights? table<integer, string>
---@param compact? boolean append directly under the previous line, no blank line
---@return Crust.Chat.Output.Block
function Output:append_block(lines, highlights, line_highlights, compact)
	local block, patch = self._transcript:append_block(lines, highlights, line_highlights, compact)

	-- The patch draws the block's highlights, along with those of everything
	-- else it rewrote.
	if not self._batch and self._view:patch(patch) then
		self:_refresh_regions()
		self:_follow()
		self:_render_markdown()
	end

	return block
end

--- Rewrite a block in place, wherever it has drifted to.
---@param block Crust.Chat.Output.Block
---@param lines string[]
---@param highlights? Crust.Chat.Tools.Highlight[]
---@param line_highlights? table<integer, string>
function Output:replace_block(block, lines, highlights, line_highlights)
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	-- The view clears the rewritten rows before it writes them and draws the
	-- block again afterwards, so nothing has to be cleared here.
	local patch = self._transcript:replace_block(block, lines, highlights, line_highlights)
	if not patch or self._batch then
		return
	end

	if self._view:patch(patch) then
		self:_refresh_regions()
		self:_follow()
		self:_render_markdown()
	end
end

--- Tool block drawn on a row, nil when the row holds prose. Defaults to the
--- row under the cursor, which is what the preview key asks for.
---@param row? integer 0-based
---@return Crust.Chat.Output.Block?
function Output:block_at(row)
	if not row then
		local win = self:win()
		if not win then
			return nil
		end
		row = vim.api.nvim_win_get_cursor(win)[1] - 1
	end

	return self._view:block_at(row)
end

--- True when nothing but blank lines follows the block, so the next block
--- can be appended directly under it.
---@param block Crust.Chat.Output.Block
---@return boolean
function Output:block_ends_buffer(block)
	return self._transcript:block_ends_transcript(block)
end

--- Start a message: a `---` rule, then the role icon and a timestamp.
--- The rule is skipped for the first message, there is nothing to separate.
---@param label string role icon, see `config.labels`
---@param group string highlight group for the icon
---@param timestamp? integer epoch seconds, defaults to now
function Output:header(label, group, timestamp)
	local format = require("crust.config").get().timestamp_format
	local time = tostring(os.date(format, timestamp or os.time()))
	local head = label .. " " .. time

	local _, index = self._transcript:begin_section(head, {
		{ line = 1, col = 0, end_col = #label, group = group },
		{ line = 1, col = #label + 1, end_col = #head, group = Highlights.TIMESTAMP },
	})

	if self._batch then
		return
	end

	if self._following then
		self._view:set_anchor(nil)
		-- The message goes under the ones on screen; only a view that has to
		-- give up its oldest message is redrawn.
		if not self._view:extend_tail() then
			self._view:rebuild()
			self:_refresh_regions()
		end
		self:_follow()
		self:_render_markdown()
	elseif self._view:rendered(index) then
		-- Rare: the tail was on screen without following it.
		self._view:rebuild()
	else
		-- The message landed off screen, only the "newer messages" hint moves.
		self._view:refresh_markers()
	end
end

--- Append message text and colour the @mentions it contains. Used for user
--- messages, where the mentions the input highlighted have to survive the
--- move into the scrollback.
---@param text string
function Output:append_message(text)
	local section, index = self._transcript:last()
	section.mentions = true

	self:append(text)

	if not self._batch then
		self._view:refresh_mentions(index)
	end
end

---@param message string
function Output:error(message)
	self:append("\n**crust: " .. message .. "**\n")
end

--- The whole conversation, whatever part of it is on screen.
---@return string[]
function Output:lines()
	return self._transcript:lines()
end

function Output:clear()
	self._transcript:clear()
	self._following = true
	self._view:set_anchor(nil)
	self._view:rebuild()
end

--- Keep parts of the buffer out of the markdown tree: tool blocks are ours,
--- not the agent's prose. Only the drawn blocks matter, the rest is not in
--- the buffer to begin with.
---@private
function Output:_refresh_regions()
	if not require("crust.config").get().raw_tool_blocks then
		return
	end

	self._regions_timer = self._regions_timer or assert(vim.uv.new_timer())
	self._regions_timer:stop()
	self._regions_timer:start(
		REGIONS_DEBOUNCE_MS,
		0,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(self._buf) then
				Regions.exclude(self._buf, self._view:block_ranges())
			end
		end)
	)
end

--- Ask render-markdown.nvim to re-render, it does not see our buffer while
--- the user is typing in the input window.
---@private
function Output:_render_markdown()
	local config = require("crust.config")
	local cfg = config.get().render_markdown
	if not config.enabled(cfg.enabled) then
		return
	end
	RenderMarkdown.render(self._buf, Output.FILETYPE, cfg.debounce_ms)
end

--- Pin the cursor to the last line while the view follows the conversation.
---@private
function Output:_follow()
	if self._following then
		self:follow()
	end
end

--- Jump to the newest message and stick to it again.
function Output:follow()
	self._following = true

	if not self._view:rendered(self._transcript:count()) then
		self._view:set_anchor(nil)
		self._view:rebuild()
	end

	local win = self:win()
	if not win then
		return
	end

	self._busy = true
	pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(self._buf), 0 })
	self._busy = false
end

--- Extend the view when the cursor reaches an elision marker, and drop
--- following as soon as the user scrolls off the newest message.
---@private
function Output:_watch_scroll()
	self._augroup = vim.api.nvim_create_augroup("crust.chat.output." .. self._buf, { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
		group = self._augroup,
		buffer = self._buf,
		callback = function()
			self:_on_scroll()
		end,
	})
end

---@private
function Output:_on_scroll()
	local win = self:win()
	if self._busy or self._batch or not win then
		return
	end

	local opts = view_opts()
	local count = vim.api.nvim_buf_line_count(self._buf)
	local _, last = self._view:range()
	local total = self._transcript:count()

	local edges = vim.api.nvim_win_call(win, function()
		return { vim.fn.line("w0"), vim.fn.line("w$") }
	end)
	local top, bottom = edges[1], edges[2]
	local cursor = vim.api.nvim_win_get_cursor(win)[1]

	self._following = last >= total and cursor >= count - 1

	-- Any marker the window is about to reach pulls its neighbours in, the
	-- pinned head and tail put one in the middle of the buffer as well.
	local target = self._view:reach(top, bottom, opts.guard_lines)
	if target then
		self:_extend(target)
	end
end

--- Re-anchor the view on `index`, keeping what is on screen where it is.
---@private
---@param index integer
function Output:_extend(index)
	if self._view:anchor() == index then
		return
	end

	local win = self:win()
	local view = win and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil
	local top = view and self._view:locate(view.topline - 1) or nil
	local cursor = view and self._view:locate(view.lnum - 1) or nil

	self._busy = true

	self._view:set_anchor(index)
	self._view:rebuild()
	self:_refresh_regions()
	self:_render_markdown()

	if win and view then
		local topline = self._view:resolve(top)
		local lnum = self._view:resolve(cursor)
		if topline and lnum then
			view.topline = topline + 1
			view.lnum = lnum + 1
			vim.api.nvim_win_call(win, function()
				vim.fn.winrestview(view)
			end)
		end
	end

	self._busy = false
end

return Output
