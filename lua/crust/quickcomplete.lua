--- Quickcomplete: ghost-text completion of the line you are typing.
---
--- A third pi process, next to the chat and quickprompt, answers one
--- question only: what finishes this line? It runs the smallest model with
--- reasoning turned off, is fed a window around the cursor rather than the
--- file, and is told to answer with raw text so its first token is already
--- the answer.
---
--- Everything that makes this feel instant happens on our side, the way
--- copilot does it:
---
---   * the generation is debounced, so a burst of keystrokes costs one call
---   * the in-flight request is aborted the moment the context moves
---   * answers are cached by context, so re-typing the same prefix, undoing
---     or coming back to a line is free
---   * generation runs in the background while you type, so by the time you
---     ask for a completion it is usually already there
---
--- The asking is explicit: `request`/`show_completion` draws what is cached
--- (or waits for the request in flight), `accept_completion` takes it, and
--- `hide_completion` drops it.

---@class Crust.QuickComplete
local M = {}

local Pi = require("crust.pi.client")
local Command = require("crust.pi.rpc")
local Highlights = require("crust.ui.highlights")

--- Markers instead of prose: the model is answering a fill-in-the-middle
--- question, and short, fixed scaffolding keeps the prefill small.
local SYSTEM_PROMPT = table.concat({
	"You are a code completion engine inside an editor. You receive a file",
	"fragment split at the cursor, and you answer with the text that should",
	"be inserted there to finish the current line.",
	"",
	"Rules, all of them absolute:",
	"- Answer with raw text only. No markdown, no code fences, no comments",
	"  about what you did, no quotes around the answer.",
	"- Answer with a single line. Never start with a newline.",
	"- Continue the line, do not repeat what is already before the cursor.",
	"- If nothing sensible can be added, answer with nothing at all.",
}, "\n")

---@alias Crust.QuickComplete.State
---| "idle" nothing in flight
---| "running" a completion is being generated
---| "error" the process failed, `message` says why

---@class Crust.QuickComplete.Status
---@field state Crust.QuickComplete.State
---@field busy boolean
---@field visible boolean ghost text is on screen
---@field cached integer completions held in the cache
---@field message string? error of the last request

---@class Crust.QuickComplete.Context
---@field buf integer
---@field filetype string
---@field row integer 0-based cursor row
---@field col integer byte column of the cursor
---@field prefix string window of text before the cursor, cursor line included
---@field suffix string window of text after the cursor
---@field line string the line the cursor is on
---@field before string text of that line left of the cursor
---@field key string identity of this context, the cache is keyed by it

--- `User` pattern fired on every state change, for statuslines.
M.EVENT = "CrustQuickComplete"

--- Namespace of the ghost text extmark.
local ns = vim.api.nvim_create_namespace("crust.quickcomplete")
M.ns = ns

---@type Crust.Pi?
local client = nil

---@type uv.uv_timer_t?
local timer = nil

--- Context -> answer. Capped, oldest dropped first. The window the answer
--- was given for is kept with it, so an answer can be reused for a context
--- that only typed into it.
---@type table<string, { completion: string, prefix: string, suffix: string }>
local cache = {}
---@type string[] insertion order of `cache`
local order = {}

--- The request in flight, nil when none.
---@type { key: string, context: Crust.QuickComplete.Context, text: string, show: boolean, pi: Crust.Pi }?
local inflight = nil

--- Where the ghost text is drawn, nil when nothing is shown.
---@type { buf: integer, id: integer, text: string, row: integer, col: integer }?
local ghost = nil

---@type Crust.QuickComplete.Status
local state = { state = "idle", busy = false, visible = false, cached = 0 }

local function announce()
	state.cached = #order
	state.visible = ghost ~= nil
	state.busy = state.state == "running"
	pcall(vim.api.nvim_exec_autocmds, "User", { pattern = M.EVENT, modeline = false })
end

---@param next_state Crust.QuickComplete.State
---@param message? string
local function set_state(next_state, message)
	state.state = next_state
	state.message = message
	announce()
end

---@return Crust.QuickComplete.Status
function M.status()
	return vim.deepcopy(state)
end

--- Cache ------------------------------------------------------------------

---@param context Crust.QuickComplete.Context
---@param completion string
local function remember(context, completion)
	if cache[context.key] == nil then
		order[#order + 1] = context.key
	end
	cache[context.key] = { completion = completion, prefix = context.prefix, suffix = context.suffix }

	local max = require("crust.config").get().quickcomplete.cache_size
	while #order > max do
		local oldest = table.remove(order, 1)
		cache[oldest] = nil
	end
end

--- The answer for `context`, if one is known.
---
--- An exact hit is the common case. Failing that, an earlier answer for the
--- same line is reused when the user simply typed the start of it: asked
--- after `local x = `, answered `a + b`, then typing `a ` leaves `+ b` to
--- suggest. That is what keeps a suggestion on screen while you type it,
--- instead of one request per keystroke.
---@param context Crust.QuickComplete.Context
---@return string? completion
function M.completion(context)
	local exact = cache[context.key]
	if exact then
		return exact.completion
	end

	for index = #order, 1, -1 do
		local entry = cache[order[index]]
		if
			entry
			and entry.completion ~= ""
			-- What follows the cursor has to be untouched: the answer was
			-- written to fit in front of it.
			and entry.suffix == context.suffix
			and #context.prefix > #entry.prefix
			and context.prefix:sub(1, #entry.prefix) == entry.prefix
		then
			local typed = context.prefix:sub(#entry.prefix + 1)
			if #typed < #entry.completion and entry.completion:sub(1, #typed) == typed then
				return entry.completion:sub(#typed + 1)
			end
		end
	end

	return nil
end

function M.clear_cache()
	cache, order = {}, {}
	announce()
end

--- Context ----------------------------------------------------------------

--- True for a buffer worth completing in: a real, modifiable buffer that is
--- not one of the chat panels.
---@param buf integer
---@return boolean
local function completable(buf)
	if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
		return false
	end
	if vim.bo[buf].buftype ~= "" then
		return false
	end

	local filetype = vim.bo[buf].filetype
	local Filetypes = require("crust.filetypes")
	return filetype ~= Filetypes.input and filetype ~= Filetypes.output
end

--- The window around the cursor the model is given.
---
--- Small on purpose: prefill time is what the user feels, and a page in each
--- direction is what a line completion can actually use. Less of it comes
--- after the cursor than before: finishing a line needs what leads up to
--- it, barely anything of what follows.
---
--- Where the window *starts* is snapped to a block of `window_step` lines
--- instead of following the cursor. Moving down a line then leaves the text
--- before the cursor byte-identical, which is what both this cache and the
--- provider's prefix cache key on; a window that slides by one line every
--- keystroke misses both.
---@param opts? { buf?: integer, row?: integer, col?: integer }
---@return Crust.QuickComplete.Context?
function M.context(opts)
	opts = opts or {}
	local buf = opts.buf or vim.api.nvim_get_current_buf()
	if not completable(buf) then
		return nil
	end

	local row, col = opts.row, opts.col
	if not row or not col then
		local cursor = vim.api.nvim_win_get_cursor(0)
		row, col = cursor[1] - 1, cursor[2]
	end

	local count = vim.api.nvim_buf_line_count(buf)
	if row >= count then
		return nil
	end

	local cfg = require("crust.config").get().quickcomplete
	local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	col = math.min(col, #line)

	local step = math.max(cfg.window_step, 1)
	local anchor = math.floor(row / step) * step
	local first = math.max(anchor - cfg.window_lines, 0)
	local last = math.min(row + cfg.suffix_lines + 1, count)
	local before_lines = vim.api.nvim_buf_get_lines(buf, first, row, false)
	local after_lines = vim.api.nvim_buf_get_lines(buf, row + 1, last, false)

	local before = line:sub(1, col)
	local prefix = table.concat(before_lines, "\n")
	prefix = (#before_lines > 0 and prefix .. "\n" or "") .. before
	local suffix = line:sub(col + 1)
	suffix = suffix .. (#after_lines > 0 and "\n" .. table.concat(after_lines, "\n") or "")

	return {
		buf = buf,
		filetype = vim.bo[buf].filetype,
		row = row,
		col = col,
		prefix = prefix,
		suffix = suffix,
		line = line,
		before = before,
		-- What the model sees is what identifies the answer: same window,
		-- same completion, whatever buffer or line number it sits on.
		key = vim.fn.sha256(prefix .. "\0" .. suffix),
	}
end

--- The request: the language, the split, nothing else. The path told the
--- model nothing a line completion can use, and every token of scaffolding
--- is prefill the user waits for.
---@param context Crust.QuickComplete.Context
---@return string
function M.prompt(context)
	return table.concat({
		"<|language|> " .. (context.filetype ~= "" and context.filetype or "text"),
		"<|prefix|>",
		context.prefix,
		"<|suffix|>",
		context.suffix,
		"<|complete|>",
	}, "\n")
end

--- Drop the part of the answer that is already on the line.
---
--- Models re-state what they are continuing: asked to finish `  echo `, a
--- model answers `echo foobar` as often as `foobar`. Whatever tail of the
--- text before the cursor the answer starts with is cut off, longest match
--- first, so the insert never duplicates it.
---
--- A single-character overlap is only cut when it is whitespace: one letter
--- in common is a coincidence, one space is the indent.
---@param line string
---@param before string
---@return string
local function strip_overlap(line, before)
	if before == "" or line == "" then
		return line
	end

	for length = math.min(#before, #line), 1, -1 do
		local tail = before:sub(#before - length + 1)
		if tail == line:sub(1, length) and (length > 1 or tail:match("^%s$")) then
			return line:sub(length + 1)
		end
	end

	return line
end

--- An answer is one line of raw text; models still fence it now and then.
---@param text string
---@param context Crust.QuickComplete.Context
---@return string completion empty when there is nothing to insert
function M.sanitize(text, context)
	local line = nil
	for _, candidate in ipairs(vim.split(text, "\n", { plain = true })) do
		if not candidate:match("^%s*```") and vim.trim(candidate) ~= "" then
			line = candidate
			break
		end
	end
	if not line then
		return ""
	end

	-- Repeating the line it was asked to continue is the classic failure.
	line = strip_overlap(line, context.before)

	return (line:gsub("%s+$", ""))
end

--- Ghost text -------------------------------------------------------------

--- Ghost text is a thing you type into, so it only belongs in insert mode.
--- A function rather than an inline check, so specs can stand in for it.
---@return boolean
function M.insert_mode()
	return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
end

---@return boolean
function M.visible()
	return ghost ~= nil
end

--- The completion currently drawn, nil when nothing is on screen.
---@return string?
function M.text()
	return ghost and ghost.text or nil
end

function M.hide_completion()
	if not ghost then
		return
	end

	if vim.api.nvim_buf_is_valid(ghost.buf) then
		vim.api.nvim_buf_clear_namespace(ghost.buf, ns, 0, -1)
	end
	ghost = nil
	announce()
end

--- Draw `completion` at the cursor of `context`.
---@param completion string
---@param context Crust.QuickComplete.Context
---@return boolean shown false for an empty completion
local function render(completion, context)
	M.hide_completion()
	if completion == "" or not M.insert_mode() then
		return false
	end

	local id = vim.api.nvim_buf_set_extmark(context.buf, ns, context.row, context.col, {
		virt_text = { { completion, Highlights.GHOST_TEXT } },
		virt_text_pos = "inline",
		-- Inline virtual text sits at the cursor's own byte position, and the
		-- gravity decides which side of it the cursor is drawn on: with left
		-- gravity the mark counts as being before the cursor, so the cursor
		-- jumps to the far end of the suggestion the moment it appears. Right
		-- gravity puts the text after the cursor, where it belongs. Nothing
		-- is ever typed into it — the next keystroke hides it.
		right_gravity = true,
		hl_mode = "combine",
	})

	ghost = { buf = context.buf, id = id, text = completion, row = context.row, col = context.col }
	announce()
	return true
end

--- Requests ---------------------------------------------------------------

--- Stop the request in flight, if any. The answer to a context the user has
--- already typed past is worthless.
function M.cancel()
	if not inflight then
		return
	end

	local pi = inflight.pi
	inflight = nil
	if pi and pi:is_running() then
		pi:send(Command.abort())
	end
	set_state("idle")
end

--- Fold one rpc event of the quickcomplete process into the request.
---@param event Crust.Pi.Event
---@private
function M.on_event(event)
	if event.type == "_process_exit" then
		client = nil
		inflight = nil
		set_state("error", "pi exited (" .. tostring(event.code) .. ")")
		return
	end

	local request = inflight
	if not request then
		return
	end

	if event.type == "message_update" then
		local ev = event.assistantMessageEvent
		if ev and ev.type == "text_delta" and ev.delta then
			request.text = request.text .. ev.delta
			-- One line is all that is wanted: the rest of the answer costs
			-- time nobody waits for.
			if request.text:find("\n", 1, true) then
				M.finish(request)
			end
		end
	elseif event.type == "agent_end" then
		M.finish(request)
	end
end

--- Store the answer of `request` and draw it when it was asked for.
---@param request { key: string, context: Crust.QuickComplete.Context, text: string, show: boolean, pi: Crust.Pi }
---@private
function M.finish(request)
	if inflight ~= request then
		return
	end
	inflight = nil

	local completion = M.sanitize(request.text, request.context)
	remember(request.context, completion)
	set_state("idle")

	if not request.show then
		return
	end

	-- The cursor may have moved while the model was thinking; the answer is
	-- cached either way, but it is only drawn where it belongs.
	local current = M.context()
	if current and current.key == request.key then
		render(completion, current)
	end
end

--- Ask the model to complete `context`.
---@param context Crust.QuickComplete.Context
---@param show? boolean draw the answer when it arrives
---@return boolean started false when the answer is already known
function M.request(context, show)
	local known = M.completion(context)
	if known ~= nil then
		if show then
			render(known, context)
		end
		return false
	end

	if inflight then
		if inflight.key == context.key then
			-- Already on its way; just remember that it is wanted on screen.
			inflight.show = inflight.show or show == true
			return false
		end
		M.cancel()
	end

	local pi = M.client()
	local ok, err = pi:connect()
	if not ok then
		set_state("error", err)
		return false
	end

	inflight = { key = context.key, context = context, text = "", show = show == true, pi = pi }
	set_state("running")

	local _, send_err = pi:send(Command.prompt(M.prompt(context)))
	if send_err then
		inflight = nil
		set_state("error", send_err)
		return false
	end

	return true
end

--- Generate for the context the cursor is in, after the quiet period.
---
--- Called from the autocmds: every keystroke restarts the timer, so a burst
--- of typing costs one request, fired once the user pauses.
---@param opts? { show?: boolean, delay?: integer }
function M.schedule(opts)
	opts = opts or {}
	local cfg = require("crust.config").get().quickcomplete

	timer = timer or assert(vim.uv.new_timer())
	timer:stop()
	timer:start(
		opts.delay or cfg.debounce_ms,
		0,
		vim.schedule_wrap(function()
			local context = M.context()
			if context then
				M.request(context, opts.show)
			end
		end)
	)
end

--- API ---------------------------------------------------------------------

--- Show the completion for the current line.
---
--- A cached answer is drawn at once — which is the common case, the
--- background generation has usually run already. Otherwise the request is
--- started now and drawn when it lands, provided the cursor has not moved.
---@param opts? { buf?: integer, row?: integer, col?: integer }
---@return boolean shown true when ghost text is on screen now
function M.show_completion(opts)
	if not M.insert_mode() then
		return false
	end

	local context = M.context(opts)
	if not context then
		return false
	end

	local completion = M.completion(context)
	if completion ~= nil then
		return render(completion, context)
	end

	M.request(context, true)
	return false
end

--- Write the accepted completion into the buffer.
---@param buf integer
---@param row integer
---@param col integer
---@param text string
local function insert(buf, row, col, text)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local win = vim.api.nvim_get_current_win()
	local showing = vim.api.nvim_win_get_buf(win) == buf
	local cursor = showing and vim.api.nvim_win_get_cursor(win) or nil

	vim.api.nvim_buf_set_text(buf, row, col, row, col, { text })

	-- Text inserted at the cursor pushes it along, the way typing does. The
	-- completion lands *after* the cursor, exactly where the ghost text was
	-- drawn, so the cursor is put back where it was.
	if cursor then
		pcall(vim.api.nvim_win_set_cursor, win, cursor)
	end
end

--- Take the completion on screen and insert it at the cursor.
---
--- Completion plugins run their mappings under `textlock` (blink.cmp does),
--- where touching the buffer raises E565. The write is tried here, where it
--- lands before the next keystroke, and deferred to the main loop when the
--- caller holds the lock.
---@return boolean accepted false when nothing was shown
function M.accept_completion()
	if not ghost then
		return false
	end

	local buf, row, col, text = ghost.buf, ghost.row, ghost.col, ghost.text
	M.hide_completion()

	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	if not pcall(insert, buf, row, col, text) then
		vim.schedule(function()
			pcall(insert, buf, row, col, text)
		end)
	end

	return true
end

--- Process ----------------------------------------------------------------

--- The quickcomplete process, started on first use when `setup` did not.
---@return Crust.Pi
function M.client()
	if client then
		return client
	end

	local cfg = require("crust.config").get().quickcomplete
	client = Pi.new({
		model = cfg.model,
		-- Nothing but the model: no session to grow, no skills to load, no
		-- context files to read, no tools to offer. Every one of those is
		-- prefill, and prefill is the latency the user sees.
		args = { "--no-session", "--no-skills", "--no-context-files", "--no-tools" },
		prompt = { system_prompt = SYSTEM_PROMPT, include_defaults = false },
		context = { enabled = false },
		extension = { enabled = false },
		log = false,
		on_event = function(event)
			M.on_event(event)
		end,
	})
	return client
end

--- Autocmds: hide what is stale, and keep generating in the background.
---@private
function M.attach()
	local group = vim.api.nvim_create_augroup("crust.quickcomplete", { clear = true })

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, {
		group = group,
		callback = function()
			-- Whatever is drawn belongs to the position before this keystroke.
			M.hide_completion()
			if require("crust.config").get().quickcomplete.auto then
				M.schedule()
			end
		end,
	})

	-- Anything that moves the cursor off the line, leaves insert mode or
	-- changes the buffer from somewhere else takes the suggestion with it.
	vim.api.nvim_create_autocmd(
		{ "InsertLeave", "InsertLeavePre", "BufLeave", "WinLeave", "CursorMoved", "TextChanged", "CompleteChanged" },
		{
			group = group,
			callback = function()
				M.hide_completion()
				M.cancel()
			end,
		}
	)
end

--- Start the process and the autocmds. Called by `crust.setup`.
---@param cfg? Crust.Config.QuickComplete
function M.setup(cfg)
	cfg = cfg or require("crust.config").get().quickcomplete
	if cfg.enabled == false then
		return
	end

	M.attach()

	vim.schedule(function()
		local pi = M.client()
		if pi:connect() then
			-- Reasoning is latency, and a line completion has nothing to
			-- reason about.
			pi:send(Command.set_thinking_level("off"))
		end
	end)
end

function M.stop()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end

	M.hide_completion()
	inflight = nil
	if client then
		client:close()
		client = nil
	end
	M.clear_cache()
	set_state("idle")
end

return M
