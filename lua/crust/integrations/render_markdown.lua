--- Optional integration with render-markdown.nvim.
---
--- The plugin only re-renders a buffer on events fired in its own window.
--- During streaming the user sits in the input window, so the output buffer
--- never gets those events. We push a render explicitly instead.
---
--- https://github.com/MeanderingProgrammer/render-markdown.nvim

---@class Crust.Integrations.RenderMarkdown
local M = {}

---@type table<integer, uv.uv_timer_t> per-buffer debounce timers
local timers = {}

--- The render-markdown api module, when the plugin is installed.
---@return table? api
function M.api()
	local ok, api = pcall(require, "render-markdown.api")
	if ok and type(api) == "table" and type(api.render) == "function" then
		return api
	end
	return nil
end

---@return boolean
function M.available()
	return M.api() ~= nil
end

--- Render now, without debouncing.
---@param buf integer
---@param filetype string the buffer's filetype, added to the plugin's file_types
function M.render_now(buf, filetype)
	local api = M.api()
	if not api or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local wins = vim.fn.win_findbuf(buf)
	if #wins == 0 then
		return
	end

	pcall(api.render, {
		buf = buf,
		win = wins,
		event = "Crust",
		config = { file_types = { filetype } },
	})
end

--- Render after a quiet period, so streaming deltas don't render per chunk.
---@param buf integer
---@param filetype string
---@param debounce_ms integer
function M.render(buf, filetype, debounce_ms)
	if not M.available() then
		return
	end

	local timer = timers[buf]
	if not timer then
		timer = assert(vim.uv.new_timer())
		timers[buf] = timer
	end

	timer:stop()
	timer:start(
		debounce_ms,
		0,
		vim.schedule_wrap(function()
			M.render_now(buf, filetype)
		end)
	)
end

--- Drop the timer of a buffer that is going away.
---@param buf integer
function M.detach(buf)
	local timer = timers[buf]
	if timer then
		timer:stop()
		timer:close()
		timers[buf] = nil
	end
end

return M
