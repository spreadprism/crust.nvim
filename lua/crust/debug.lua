--- The raw rpc of the live processes, in a buffer.
---
--- The chat shows what pi reported; this shows what crossed the pipe. Every
--- `Crust.Pi` records its own traffic in memory as it happens — the command
--- it was spawned with, every line written to its stdin, every line read
--- from its stdout, every line it wrote to stderr, and its exit — so a
--- failure can be read after the fact instead of being reproduced with
--- `log.enabled` turned on.
---
---     :Crust debug
---     require("crust").debug()
---
--- Each line is one pipe event:
---
---     09:05:11.412 $ pi --mode rpc  (cwd: /home/me/project)
---     09:05:11.430 > {"type":"prompt","id":"crust:2",…}
---     09:05:11.930 < {"type":"agent_start",…}
---     09:05:12.004 ! Error: OAuth refresh failed for anthropic: …
---     09:05:12.010 x pi exited with 1
---
--- `config.debug.history` caps what is kept per process (the tail), and
--- `config.debug.pretty` expands the json over several rows.

---@class Crust.Debug
local M = {}

M.BUFNAME = "crust://debug"

--- Glyph in front of each line, so a grep can pick one direction out.
---@type table<Crust.Pi.Trace.Kind, string>
local MARKERS = {
	spawn = "$",
	sent = ">",
	received = "<",
	stderr = "!",
	exit = "x",
}

---@param time integer epoch milliseconds
---@return string
local function stamp(time)
	return string.format("%s.%03d", os.date("%H:%M:%S", math.floor(time / 1000)), time % 1000)
end

--- Expand a json payload over several rows, when it is json at all.
---@param text string
---@return string[]
local function pretty(text)
	local ok, decoded = pcall(vim.json.decode, text)
	if not ok or type(decoded) ~= "table" then
		return { text }
	end
	return vim.split(vim.inspect(decoded), "\n", { plain = true })
end

--- One process' traffic, as buffer lines.
---@param pi Crust.Pi
---@param opts? { pretty?: boolean }
---@return string[]
function M.trace_lines(pi, opts)
	opts = opts or {}
	local expand = opts.pretty
	if expand == nil then
		expand = require("crust.config").get().debug.pretty
	end

	local lines = {}
	for _, entry in ipairs(pi:trace()) do
		local prefix = stamp(entry.time) .. " " .. (MARKERS[entry.kind] or "?") .. " "
		-- A stderr line may be a whole stack trace; it stays whole, indented
		-- under its own timestamp rather than cut to one row.
		local parts = expand and entry.kind ~= "stderr" and pretty(entry.text)
			or vim.split(entry.text, "\n", { plain = true })

		for index, part in ipairs(parts) do
			lines[#lines + 1] = (index == 1 and prefix or string.rep(" ", #prefix)) .. part
		end
	end

	if #lines == 0 then
		lines[1] = "  (no traffic recorded)"
	end
	return lines
end

--- The processes crust is running right now, in the order they matter for
--- debugging. Only live ones: nothing here starts a process.
---@return { name: string, pi: Crust.Pi }[]
function M.processes()
	local found = {}

	local chat = require("crust").current_chat()
	if chat then
		local session = chat:session()
		local name = "chat"
		if session.name or session.id then
			name = name .. " (" .. tostring(session.name or session.id) .. ")"
		end
		found[#found + 1] = { name = name, pi = chat:pi() }
	end

	local quickprompt = require("crust.quickprompt").process()
	if quickprompt then
		found[#found + 1] = { name = "quickprompt", pi = quickprompt }
	end

	local quickcomplete = require("crust.quickcomplete").process()
	if quickcomplete then
		found[#found + 1] = { name = "quickcomplete", pi = quickcomplete }
	end

	return found
end

--- The whole dump: one section per live process.
---@param opts? { pretty?: boolean }
---@return string[]
function M.lines(opts)
	local lines = {
		"# crust debug — " .. os.date("%Y-%m-%d %H:%M:%S"),
		"",
		"# $ spawn   > sent   < received   ! stderr   x exit",
	}

	local processes = M.processes()
	if #processes == 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "No pi process is running."
		return lines
	end

	for _, process in ipairs(processes) do
		local pi = process.pi
		local state = pi:is_running() and ("running, job " .. tostring(pi.job_id)) or "not running"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "## " .. process.name .. " [" .. state .. "]"
		-- The model is part of the question "why did this answer look like
		-- that", so it is in the header rather than only in the spawn line.
		lines[#lines + 1] = "   model: " .. tostring(pi.opts.model or "default") .. ", cwd: " .. tostring(pi.opts.cwd)
		lines[#lines + 1] = ""
		vim.list_extend(lines, M.trace_lines(pi, opts))
	end

	return lines
end

--- Open the dump in a new tab. The buffer is a snapshot: reopen it to
--- refresh.
---@param opts? { pretty?: boolean }
---@return integer buf
function M.open(opts)
	local lines = M.lines(opts)

	local existing = vim.fn.bufnr(M.BUFNAME)
	if existing ~= -1 then
		pcall(vim.api.nvim_buf_delete, existing, { force = true })
	end

	local buf = vim.api.nvim_create_buf(true, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	vim.bo[buf].filetype = "crust_debug"
	pcall(vim.api.nvim_buf_set_name, buf, M.BUFNAME)

	vim.cmd("tabnew")
	vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
	vim.api.nvim_win_set_cursor(0, { #lines, 0 })

	return buf
end

return M
