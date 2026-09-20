--- Session picker.
---
--- Uses snacks.nvim when it is installed, as a plain list of session names
--- whose entries can be deleted with the delete key, and falls back to
--- `vim.ui.select`.

local M = {}

local Sessions = require("crust.sessions")
local Highlights = require("crust.ui.highlights")

--- Deletes the selected sessions from inside the picker.
M.DELETE_KEY = "<C-d>"

---@class Crust.Sessions.Picker.Opts
---@field cwd? string sessions of this directory, defaults to the current one
---@field title? string picker title
---@field on_delete? fun(paths: string[]) called with the session files removed

---@param session Crust.Session
---@return snacks.picker.finder.Item
local function item(session)
	return { session = session, text = Sessions.label(session) }
end

---@param session Crust.Session
---@return string
local function line(session)
	return Sessions.date(session) .. "  " .. Sessions.label(session)
end

---@param sessions Crust.Session[]
---@param opts Crust.Sessions.Picker.Opts
---@param on_choice fun(session: Crust.Session?)
local function snacks_pick(sessions, opts, on_choice)
	---@type snacks.picker.finder.Item[]
	local items = vim.tbl_map(item, sessions)

	require("snacks").picker.pick({
		source = "crust_sessions",
		title = opts.title or "Crust sessions",
		items = items,
		-- Names are all we show: no preview, and the `select` preset hides the
		-- preview window entirely.
		preview = "none",
		layout = { preset = "select" },
		format = function(entry)
			local session = entry.session --[[@as Crust.Session]]
			return {
				{ Sessions.date(session) .. "  ", Highlights.TIMESTAMP },
				{ Sessions.label(session), Highlights.USER_TITLE },
			}
		end,
		confirm = function(picker, entry)
			picker:close()
			on_choice(entry and entry.session or nil)
		end,
		actions = {
			---@param picker snacks.Picker
			crust_delete_session = function(picker)
				M.delete(picker:selected({ fallback = true }), function(deleted)
					-- The finder is a static list, so it is rebuilt from disk.
					picker.opts.items = vim.tbl_map(item, Sessions.list(opts.cwd))
					picker:find()
					if opts.on_delete and #deleted > 0 then
						opts.on_delete(deleted)
					end
				end)
			end,
		},
		win = {
			input = {
				keys = {
					[M.DELETE_KEY] = { "crust_delete_session", mode = { "i", "n" }, desc = "crust: delete session" },
				},
			},
			list = {
				keys = { [M.DELETE_KEY] = { "crust_delete_session", mode = { "n" }, desc = "crust: delete session" } },
			},
		},
	})
end

--- Delete the sessions behind the given picker items, after confirmation.
---@param entries { session: Crust.Session }[]
---@param on_done? fun(deleted: string[]) paths that were removed
function M.delete(entries, on_done)
	if #entries == 0 then
		return
	end

	local prompt = #entries == 1 and ("Delete session '" .. Sessions.label(entries[1].session) .. "'?")
		or ("Delete " .. #entries .. " sessions?")
	if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
		return
	end

	---@type string[]
	local deleted = {}
	for _, entry in ipairs(entries) do
		local ok, err = Sessions.delete(entry.session.path)
		if ok then
			deleted[#deleted + 1] = entry.session.path
		else
			vim.notify("crust: " .. tostring(err), vim.log.levels.ERROR)
		end
	end

	if on_done then
		on_done(deleted)
	end
end

---@param sessions Crust.Session[]
---@param opts Crust.Sessions.Picker.Opts
---@param on_choice fun(session: Crust.Session?)
local function ui_select(sessions, opts, on_choice)
	vim.ui.select(sessions, {
		prompt = opts.title or "Crust sessions",
		kind = "crust-sessions",
		format_item = line,
	}, on_choice)
end

--- Pick one of the sessions recorded for `cwd`.
--- `<CR>` picks it, and with snacks.nvim `<C-d>` deletes the selection.
---@param opts? Crust.Sessions.Picker.Opts
---@param on_choice fun(session: Crust.Session?) called with nil when cancelled
function M.select(opts, on_choice)
	opts = opts or {}

	local sessions = Sessions.list(opts.cwd)
	if #sessions == 0 then
		on_choice(nil)
		return
	end

	if M.has_snacks() then
		snacks_pick(sessions, opts, on_choice)
	else
		ui_select(sessions, opts, on_choice)
	end
end

---@return boolean
function M.has_snacks()
	local ok, snacks = pcall(require, "snacks")
	return ok and type(snacks) == "table" and snacks.picker ~= nil
end

return M
