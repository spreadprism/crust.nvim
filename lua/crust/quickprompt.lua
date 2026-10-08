--- Quickprompt: one-shot edits of the buffer you are in.
---
--- A second pi process, separate from the chat and from its session, takes a
--- line of instruction plus the buffer around the cursor and answers by
--- calling its `edit` tool. Nothing is written into a panel: either the file
--- changes, or the model reports why it did not, and that report is handed
--- to `vim.notify`.
---
--- The process is small and cheap on purpose (haiku by default), and it is
--- started once, after `setup`, so the first prompt does not pay for it.
---
--- The live state is `M.status()`, meant for a statusline:
---
---     require("crust.quickprompt").status() -- { state = "running", … }

---@class Crust.QuickPrompt
local M = {}

local Pi = require("crust.pi.client")
local Command = require("crust.pi.rpc")

---@alias Crust.QuickPrompt.State
---| "idle" nothing is running
---| "running" the model is working on a request
---| "error" the last request failed, `message` says why

---@class Crust.QuickPrompt.Status
---@field state Crust.QuickPrompt.State
---@field busy boolean the model is working, same as `state == "running"`
---@field prompt string? instruction of the last request
---@field message string? error of the last request
---@field since integer? epoch seconds the state was entered

---@class Crust.QuickPrompt.Context
---@field buf integer
---@field path string absolute path of the file
---@field filetype string
---@field lines string[] the whole buffer
---@field first integer 1-based first line of the region of interest
---@field last integer inclusive last line of the region
---@field visual boolean the region is a selection, not a window around the cursor

---@class Crust.QuickPrompt.Opts
---@field buf? integer defaults to the current buffer
---@field visual? boolean use the selection; defaults to "am I in visual mode"
---@field first? integer 1-based first line, for callers with a range of their own
---@field last? integer inclusive last line, defaults to `first`
---@field prompt? string skip the input box and run this instruction

--- The model is told what to do once, on the command line of its process.
local SYSTEM_PROMPT = table.concat({
	"You are an inline code editor inside neovim. You are given a file, the",
	"region of it the user is looking at, and one instruction.",
	"",
	"Apply the instruction by calling the `edit` tool on that file, and only",
	"on that file. Keep the change as small as the instruction asks for, and",
	"leave the rest of the file alone.",
	"",
	"Never write prose, never explain, never ask questions: a successful edit",
	"is answered with no text at all.",
	"",
	"If you cannot apply the instruction — it is ambiguous, the region does",
	"not contain what it refers to, or the edit fails — make no change and",
	"answer with a single line of the form:",
	"",
	"ERROR: <short reason>",
}, "\n")

--- An answer that starts like this is a failure report, not an edit.
local ERROR_PREFIX = "^ERROR:%s*"

---@type Crust.Pi?
local client = nil

---@type Crust.QuickPrompt.Status
local status = { state = "idle", busy = false }

--- Text streamed back by the model for the running request.
---@type string
local answer = ""

---@type fun(ok: boolean, err: string?)?
local pending = nil

--- `User` pattern fired whenever the state changes, so a statusline can
--- redraw without polling.
M.EVENT = "CrustQuickPrompt"

---@param state Crust.QuickPrompt.State
---@param fields? { prompt?: string, message?: string }
local function set_status(state, fields)
	status = vim.tbl_extend("force", {
		state = state,
		busy = state == "running",
		prompt = status.prompt,
		since = os.time(),
	}, fields or {})

	pcall(vim.api.nvim_exec_autocmds, "User", { pattern = M.EVENT, modeline = false })
end

--- Live state of the feature, safe to poll from a statusline.
---@return Crust.QuickPrompt.Status
function M.status()
	return vim.deepcopy(status)
end

---@return boolean busy
function M.busy()
	return status.busy
end

--- Finish the running request: tell the caller, notify a failure, and let
--- the buffers pick up what was written under them.
---@param ok boolean
---@param err string?
local function settle(ok, err)
	local callback = pending
	pending = nil
	answer = ""

	if ok then
		set_status("idle", { message = nil })
	else
		set_status("error", { message = err })
		vim.notify("crust quickprompt: " .. (err or "failed"), vim.log.levels.ERROR)
	end

	-- The edit landed on disk, the buffer still holds what was there before.
	if ok and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "c" then
		pcall(vim.cmd.checktime)
	end

	if callback then
		callback(ok, err)
	end
end

--- Fold one rpc event of the quickprompt process into the run.
---@param event Crust.Pi.Event
---@private
function M.on_event(event)
	if not pending then
		return
	end

	if event.type == "message_update" then
		local ev = event.assistantMessageEvent
		if ev and ev.type == "text_delta" and ev.delta then
			answer = answer .. ev.delta
		end
	elseif event.type == "agent_end" then
		local text = vim.trim(answer)
		if text:match(ERROR_PREFIX) then
			settle(false, (text:gsub(ERROR_PREFIX, "")))
		else
			settle(true)
		end
	elseif event.type == "_stderr" then
		-- Only a hard failure ends the run; pi writes warnings here too.
		local Errors = require("crust.pi.errors")
		local text = tostring(event.message)
		if Errors.is_error(text) then
			settle(false, Errors.pretty(text))
		end
	elseif event.type == "_process_exit" then
		client = nil
		settle(false, "pi exited (" .. tostring(event.code) .. ")")
	end
end

--- The live quickprompt process, without starting one. For `crust.debug`
--- and anything else that only wants to look.
---@return Crust.Pi?
function M.process()
	return client
end

--- The quickprompt process, started on first use when `setup` did not.
---@return Crust.Pi
function M.client()
	if client then
		return client
	end

	local cfg = require("crust.config").get().quickprompt
	client = Pi.new({
		model = cfg.model,
		-- Nothing of the chat's world applies here: no stored session to
		-- grow, no project context files, no neovim extension. The prompt
		-- carries everything the model is allowed to know, and `edit` is
		-- the only thing it is allowed to do.
		args = {
			"--no-session",
			"--no-extensions",
			"--no-skills",
			"--no-prompt-templates",
			"--no-themes",
			"--no-approve",
			"--offline",
			"--tools",
			"edit,read",
			"--thinking",
			"off",
		},
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

--- Start the process ahead of the first prompt. Called by `crust.setup`.
---@param cfg? Crust.Config.QuickPrompt defaults to the configured one
function M.setup(cfg)
	cfg = cfg or require("crust.config").get().quickprompt
	if cfg.enabled == false then
		return
	end

	vim.schedule(function()
		M.client():connect()
	end)
end

function M.stop()
	if client then
		client:close()
		client = nil
	end
	pending = nil
	answer = ""
	set_status("idle", { message = nil, prompt = nil })
end

---@return boolean
local function in_visual_mode()
	return vim.fn.mode():match("^[vV\22]") ~= nil
end

--- The region the request is about: the selection in visual mode, a window
--- of `context_lines` around the cursor otherwise.
---@param opts? Crust.QuickPrompt.Opts
---@return Crust.QuickPrompt.Context? context nil for a buffer with no file
function M.context(opts)
	opts = opts or {}
	local buf = opts.buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end

	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return nil
	end

	local visual = opts.visual
	if visual == nil then
		visual = opts.first ~= nil or in_visual_mode()
	end

	local count = vim.api.nvim_buf_line_count(buf)
	local first, last
	if opts.first then
		first, last = opts.first, opts.last or opts.first
	elseif visual then
		first, last = vim.fn.line("v"), vim.fn.line(".")
	else
		local around = require("crust.config").get().quickprompt.context_lines
		local row = vim.api.nvim_win_get_cursor(0)[1]
		first, last = row - around, row + around
	end

	if first > last then
		first, last = last, first
	end
	first = math.max(math.min(first, count), 1)
	last = math.max(math.min(last, count), 1)

	return {
		buf = buf,
		path = vim.fs.normalize(name),
		filetype = vim.bo[buf].filetype,
		lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
		first = first,
		last = last,
		visual = visual == true,
	}
end

--- The message sent to the model: the file whole, numbered so the region can
--- be pointed at by line, then the region itself, then the instruction.
---@param prompt string
---@param context Crust.QuickPrompt.Context
---@return string
function M.message(prompt, context)
	local numbered = {}
	for index, line in ipairs(context.lines) do
		numbered[index] = index .. "\t" .. line
	end

	local region = vim.list_slice(context.lines, context.first, context.last)
	local fence = context.filetype ~= "" and context.filetype or ""

	return table.concat({
		"File: " .. context.path,
		"",
		"Whole file, line numbers prefixed:",
		"```" .. fence,
		table.concat(numbered, "\n"),
		"```",
		"",
		(context.visual and "Selected lines " or "Lines ") .. context.first .. "-" .. context.last .. ":",
		"```" .. fence,
		table.concat(region, "\n"),
		"```",
		"",
		"Instruction: " .. prompt,
	}, "\n")
end

--- Send one instruction about `context` to the model.
---@param prompt string
---@param context Crust.QuickPrompt.Context
---@param callback? fun(ok: boolean, err: string?)
---@return boolean started
function M.run(prompt, context, callback)
	if status.busy then
		vim.notify("crust quickprompt: already running", vim.log.levels.WARN)
		return false
	end

	local pi = M.client()
	local ok, err = pi:connect()
	if not ok then
		set_status("error", { prompt = prompt, message = err })
		vim.notify("crust quickprompt: " .. (err or "failed to start pi"), vim.log.levels.ERROR)
		if callback then
			callback(false, err)
		end
		return false
	end

	answer = ""
	pending = callback or function() end
	set_status("running", { prompt = prompt, message = nil })

	local _, send_err = pi:send(Command.prompt(M.message(prompt, context)))
	if send_err then
		settle(false, send_err)
		return false
	end

	return true
end

--- Ask for an instruction and run it against the current context.
---
--- The context is read before the input box opens: `vim.ui.input` ends
--- visual mode, which would take the selection with it.
---@param opts? Crust.QuickPrompt.Opts
---@param callback? fun(ok: boolean, err: string?)
---@return boolean asked false when there is nothing to edit
function M.ask(opts, callback)
	local context = M.context(opts)
	if not context then
		vim.notify("crust quickprompt: no file in this buffer", vim.log.levels.WARN)
		return false
	end

	local given = opts and opts.prompt
	if given and vim.trim(given) ~= "" then
		return M.run(vim.trim(given), context, callback)
	end

	vim.ui.input({ prompt = "Quickprompt: " }, function(value)
		if not value or vim.trim(value) == "" then
			return
		end
		M.run(vim.trim(value), context, callback)
	end)
	return true
end

return M
