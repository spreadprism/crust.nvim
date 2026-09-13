--- Highlight groups. Every group is defined with `default = true`, so a user
--- or colorscheme definition always wins.

---@class Crust.Highlights
local M = {}

M.SEPARATOR = "CrustSeparator"
M.USER_TITLE = "CrustUserTitle"
M.AGENT_TITLE = "CrustAgentTitle"
M.TIMESTAMP = "CrustTimestamp"
M.TOOL = "CrustTool"
M.TOOL_TITLE = "CrustToolTitle"
M.TOOL_BODY = "CrustToolBody"
M.TOOL_BODY_INLINE = "CrustToolBodyInline"
M.TOOL_PREFIX = "CrustToolPrefix"
M.TOOL_BACKGROUND = "CrustToolBackground"
M.TOOL_BODY_BACKGROUND = "CrustToolBodyBackground"
M.TOOL_ICON_PENDING = "CrustToolIconPending"
M.TOOL_ICON_SUCCESS = "CrustToolIconSuccess"
M.TOOL_ICON_ERROR = "CrustToolIconError"

---@type table<string, vim.api.keyset.highlight>
M.groups = {
	[M.SEPARATOR] = { link = "WinSeparator" },
	[M.USER_TITLE] = { link = "Identifier" },
	[M.AGENT_TITLE] = { link = "Special" },
	[M.TIMESTAMP] = { link = "Comment" },
	[M.TOOL] = { link = "Constant" },
	[M.TOOL_TITLE] = { link = "Directory" },
	[M.TOOL_BODY] = { link = "Normal" },
	[M.TOOL_BODY_INLINE] = { link = "Comment" },
	[M.TOOL_PREFIX] = { link = "Comment" },
	-- Code-block shading. RenderMarkdownCode comes from render-markdown.nvim;
	-- CursorLine is the fallback when that plugin is absent.
	[M.TOOL_BACKGROUND] = { link = "RenderMarkdownCode" },
	[M.TOOL_BODY_BACKGROUND] = { link = "RenderMarkdownCode" },
	[M.TOOL_ICON_PENDING] = { link = "DiagnosticWarn" },
	[M.TOOL_ICON_SUCCESS] = { link = "DiagnosticOk" },
	[M.TOOL_ICON_ERROR] = { link = "DiagnosticError" },
}

---@type table<Crust.Chat.Tools.Status, string>
M.tool_icon = {
	pending = M.TOOL_ICON_PENDING,
	success = M.TOOL_ICON_SUCCESS,
	error = M.TOOL_ICON_ERROR,
}

local applied = false

--- Define the groups once, and redefine them after a colorscheme change.
---@param force? boolean redefine even if already applied
function M.setup(force)
	if applied and not force then
		return
	end
	applied = true

	-- Without render-markdown.nvim the code group does not exist, so the
	-- shading falls back to CursorLine.
	if vim.fn.hlexists("RenderMarkdownCode") == 0 then
		vim.api.nvim_set_hl(0, "RenderMarkdownCode", { link = "CursorLine", default = true })
	end

	for name, def in pairs(M.groups) do
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
	end

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("crust.highlights", { clear = true }),
		callback = function()
			for name, def in pairs(M.groups) do
				vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
			end
		end,
	})
end

return M
