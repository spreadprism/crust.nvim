--- `:Crust usage`, the plan limits in a float.
---
--- The same block the `claude-usage` skill prints, highlighted instead of
--- ansi-coloured. The window opens straight away on whatever is cached (or
--- on a "loading" line) and repaints when the request answers, so the
--- command never feels like it hangs on the network.

---@class Crust.Ui.Usage
local M = {}

local Highlights = require("crust.ui.highlights")
local Render = require("crust.usage.render")
local Usage = require("crust.usage")

M.ns = vim.api.nvim_create_namespace("crust.ui.usage")

--- At most one float, a second call replaces it.
---@type integer?
local current = nil
---@type integer?
local current_buf = nil

---@return integer?
function M.win()
	if current and vim.api.nvim_win_is_valid(current) then
		return current
	end
	return nil
end

--- Close the open float, if any.
---@return boolean closed
function M.close()
	local win = current
	current, current_buf = nil, nil
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
		return true
	end
	return false
end

--- What to draw for the current state of the module.
---@param data Crust.Usage.Data?
---@param err string?
---@return string[] lines
---@return Crust.Usage.Highlight[] highlights
function M.content(data, err)
	if not data then
		local text = err or (Usage.is_loading() and "Loading…" or "No usage data.")
		return { "Claude plan usage", "  " .. text }, {
			{ line = 1, col = 0, end_col = #"Claude plan usage", group = Highlights.USAGE_TITLE },
			{ line = 2, col = 0, end_col = #text + 2, group = err and Highlights.USAGE_ERROR or Highlights.USAGE_DIM },
		}
	end

	local lines, highlights = Render.lines(data)

	if err then
		-- A stale answer is better than none, but say so.
		local note = "  note: " .. err
		lines[#lines + 1] = note
		highlights[#highlights + 1] =
			{ line = #lines, col = 0, end_col = #note, group = Highlights.USAGE_WARNING }
	end

	return lines, highlights
end

---@param buf integer
---@param lines string[]
---@param highlights Crust.Usage.Highlight[]
local function paint(buf, lines, highlights)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
	for _, hl in ipairs(highlights) do
		pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, hl.line - 1, hl.col, {
			end_col = hl.end_col,
			hl_group = hl.group,
		})
	end
end

---@param lines string[]
---@return integer width
---@return integer height
local function dimensions(lines)
	local width = 20
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	return math.min(width + 1, vim.o.columns - 4), math.max(math.min(#lines, vim.o.lines - 4), 1)
end

--- Draw `lines` in the open float, resizing it to fit.
---@private
---@param lines string[]
---@param highlights Crust.Usage.Highlight[]
local function repaint(lines, highlights)
	local win, buf = M.win(), current_buf
	if not win or not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	paint(buf, lines, highlights)
	local width, height = dimensions(lines)
	pcall(vim.api.nvim_win_set_config, win, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
		col = math.floor((vim.o.columns - width) / 2),
	})
end

--- Open the float and refresh it. `opts.force` skips the cache.
---@param opts? { force?: boolean }
---@return integer? win
function M.open(opts)
	opts = opts or {}
	Highlights.setup()
	M.close()

	local data, err = Usage.peek(), Usage.error()
	local lines, highlights = M.content(data, data and nil or err)
	local width, height = dimensions(lines)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = "wipe"
	paint(buf, lines, highlights)

	local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " claude usage ",
		title_pos = "center",
	})
	if not ok then
		vim.api.nvim_buf_delete(buf, { force = true })
		return nil
	end

	current, current_buf = win, buf
	vim.wo[win].wrap = false
	vim.wo[win].winfixbuf = true

	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			M.close()
		end, { buffer = buf, nowait = true, desc = "crust: close the usage float" })
	end

	-- `r` asks Anthropic again, ignoring the 60s cache.
	vim.keymap.set("n", "r", function()
		M.refresh(true)
	end, { buffer = buf, nowait = true, desc = "crust: refresh the plan usage" })

	vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(function()
				if current == win then
					M.close()
				end
			end)
		end,
	})

	M.refresh(opts.force)
	return win
end

--- Ask for the numbers and repaint when they land.
---@param force? boolean bypass the 60s cache
function M.refresh(force)
	local function done(data, err)
		vim.schedule(function()
			local lines, highlights = M.content(data, err)
			repaint(lines, highlights)
		end)
	end

	if force then
		Usage.fetch(done)
	else
		Usage.get(done)
	end

	if Usage.is_loading() and not Usage.peek() then
		repaint(M.content(nil, nil))
	end
end

return M
