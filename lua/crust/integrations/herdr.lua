--- Optional integration with herdr, the terminal runtime coding agents run
--- in: https://herdr.dev
---
--- herdr does not look at what a pane draws for agents that speak to it. It
--- puts `HERDR_ENV=1`, `HERDR_PANE_ID` and `HERDR_BIN_PATH` into the pane's
--- environment, and the agent running there reports its own state back
--- through that binary. A pane that reported is listed in the sidebar and in
--- `herdr agent list`, notifies when a turn ends, and can be waited on with
--- `herdr agent wait`.
---
--- Crust is that agent here: neovim holds the session, so neovim does the
--- reporting. The chat turn drives it — `working` while pi answers, `idle`
--- once it settles — and the pane is released when neovim quits.
---
--- On by default, and silent unless herdr put `HERDR_ENV`, `HERDR_PANE_ID`
--- and `HERDR_BIN_PATH` into the environment: outside a herdr pane there is
--- nothing to report to, so nothing is spawned and no autocmd is registered.
--- `herdr = { enabled = false }` keeps crust out of the pane anyway.
---
--- https://herdr.dev/docs/add-herdr-support/

---@class Crust.Integrations.Herdr
local M = {}

---@alias Crust.Herdr.State
---| "idle" ready for a prompt
---| "working" a turn is running
---| "blocked" the user has to decide something

---@class Crust.Herdr.Env what herdr put into the pane's environment
---@field pane string `HERDR_PANE_ID`
---@field bin string `HERDR_BIN_PATH`, the herdr binary owning this pane
---@field socket string? `HERDR_SOCKET_PATH`, unused: the CLI is the portable path

--- Reports must never slow the editor down, so a late one is dropped rather
--- than waited on.
local TIMEOUT_MS = 1500

--- Last state handed to herdr, nil before the first report and after a
--- release.
---@type Crust.Herdr.State?
local reported = nil

--- A report is in flight: further states are collapsed into `queued`, so a
--- burst of transitions ends as one call carrying the latest one.
local inflight = false

---@type { state: Crust.Herdr.State, message: string? }?
local queued = nil

--- Monotonic across sessions: herdr discards a report whose seq is not
--- higher than the last one it accepted from this source.
local seq = 0

--- Panels of the editor that are busy, keyed by name. Any of them makes the
--- agent `working`.
---@type table<string, boolean>
local busy = {}

local augroup = nil

---@return Crust.Config.Herdr
local function options()
	return require("crust.config").get().herdr
end

--- The three variables herdr exports into every pane. All of them or
--- nothing: a half-set environment is not a herdr pane.
---@return Crust.Herdr.Env? env
function M.env()
	if vim.env.HERDR_ENV ~= "1" then
		return nil
	end

	local pane, bin = vim.env.HERDR_PANE_ID, vim.env.HERDR_BIN_PATH
	if not pane or pane == "" or not bin or bin == "" then
		return nil
	end

	return { pane = pane, bin = bin, socket = vim.env.HERDR_SOCKET_PATH }
end

--- True when reports are switched on and there is a herdr to report to.
---@return boolean
function M.available()
	return require("crust.config").enabled(options().enabled) and M.env() ~= nil
end

--- State herdr was last told about.
---@return Crust.Herdr.State?
function M.state()
	return reported
end

---@return integer
local function next_seq()
	seq = math.max(seq + 1, os.time() * 1000)
	return seq
end

--- Argv of one report, or of the release when `state` is nil.
---
--- Separate from the spawning so a spec can read what would be sent, and so
--- the flags stay in one place.
---@param state Crust.Herdr.State? nil builds the `release-agent` call
---@param opts? { message?: string, seq?: integer }
---@return string[]? argv nil outside a herdr pane
function M.command(state, opts)
	local env = M.env()
	if not env then
		return nil
	end

	opts = opts or {}
	local cfg = options()
	local argv = {
		env.bin,
		"pane",
		state and "report-agent" or "release-agent",
		env.pane,
		"--source",
		cfg.source,
		"--agent",
		cfg.agent,
	}

	if state then
		vim.list_extend(argv, { "--state", state })
	end
	vim.list_extend(argv, { "--seq", tostring(opts.seq or next_seq()) })

	-- A blocked agent is worth a reason in the sidebar; the others speak for
	-- themselves.
	if opts.message and opts.message ~= "" then
		vim.list_extend(argv, { "--message", opts.message })
	end

	return argv
end

--- Run one herdr call. Replaced in specs; failures are ignored on purpose,
--- a missing or old herdr binary must not surface in the editor.
---
--- `opts.sync` waits for the call to finish instead of answering on the
--- event loop. Quitting needs it: neovim kills its children on the way out,
--- so a release left in flight is killed before herdr hears it, and the
--- agent stays in the sidebar forever.
---@param argv string[]
---@param on_exit fun()
---@param opts? { sync?: boolean }
function M.spawn(argv, on_exit, opts)
	if opts and opts.sync then
		local ok, handle = pcall(vim.system, argv, { text = true, timeout = TIMEOUT_MS })
		if ok then
			pcall(function()
				handle:wait(TIMEOUT_MS)
			end)
		end
		on_exit()
		return
	end

	local ok = pcall(vim.system, argv, { text = true, timeout = TIMEOUT_MS }, function()
		vim.schedule(on_exit)
	end)
	if not ok then
		on_exit()
	end
end

---@param state Crust.Herdr.State
---@param message string?
local function send(state, message)
	inflight = true
	reported = state

	local argv = M.command(state, { message = message })
	if not argv then
		inflight = false
		return
	end

	M.spawn(argv, function()
		inflight = false
		local next_report = queued
		queued = nil
		if next_report then
			send(next_report.state, next_report.message)
		end
	end)
end

--- Tell herdr what crust is doing. Repeating the live state costs nothing.
---@param state Crust.Herdr.State
---@param opts? { message?: string, force?: boolean } `force` reports even when the state did not change
---@return boolean sent false when the integration is off, or the state is already the reported one
function M.report(state, opts)
	opts = opts or {}
	if not M.available() then
		return false
	end

	if inflight then
		-- Only the latest state matters: herdr would discard the older ones
		-- by their seq anyway, and a queue of them would lag behind the turn.
		if not opts.force and not queued and state == reported then
			return false
		end
		queued = { state = state, message = opts.message }
		return true
	end

	if not opts.force and state == reported then
		return false
	end

	send(state, opts.message)
	return true
end

--- Mark one part of the editor busy or done, and report the state that
--- follows from it: `working` while anything is, `idle` once nothing is.
---
--- The chat uses it for its turn; a plugin wiring another long-running job
--- into the same indicator can use its own key.
---@param name string e.g. "chat"
---@param value boolean
---@return boolean sent
function M.busy(name, value)
	busy[name] = value or nil

	if next(busy) then
		return M.report("working")
	end
	return M.report("idle")
end

--- Hand the pane back: crust's name, state and resume command are cleared
--- from it right away.
---@param opts? { sync?: boolean } wait for herdr to answer, for `VimLeavePre`
---@return boolean sent
function M.release(opts)
	if not M.available() then
		return false
	end

	busy = {}
	queued = nil
	reported = nil
	-- Whatever was in flight is about to be irrelevant, and its callback
	-- must not revive the agent by sending the queued state after this.
	inflight = false

	local argv = M.command(nil)
	if not argv then
		return false
	end

	M.spawn(argv, function() end, { sync = opts and opts.sync or nil })
	return true
end

--- Claim the pane and keep it in step with the editor's life. Called from
--- `crust.setup`, a no-op outside herdr or with the integration off.
---@return boolean enabled
function M.setup()
	if not M.available() then
		return false
	end

	augroup = vim.api.nvim_create_augroup("crust.herdr", { clear = true })

	-- Released once, on whichever of the two fires first: `VimLeavePre` is
	-- skipped when the editor is torn down by `:qa!` from a modified buffer
	-- handler or by a fatal error, `VimLeave` still runs.
	local released = false
	vim.api.nvim_create_autocmd({ "VimLeavePre", "VimLeave" }, {
		group = augroup,
		callback = function()
			if released then
				return
			end
			released = true
			-- Synchronous: neovim kills the children it still owns as it
			-- exits, and a killed release leaves the agent listed.
			M.release({ sync = true })
		end,
	})

	-- The pane is crust's from here: herdr only lists an agent that reported.
	M.report("idle", { force = true })
	return true
end

--- Forget everything, for specs and for `crust.stop`.
---@private
function M.reset()
	busy = {}
	queued = nil
	reported = nil
	inflight = false
	if augroup then
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		augroup = nil
	end
end

return M
