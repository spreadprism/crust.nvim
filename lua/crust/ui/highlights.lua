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
M.STATUS = "CrustOutputStatus"
M.STATUS_ICON = "CrustOutputStatusIcon"
M.STATUS_TIME = "CrustOutputStatusTime"
M.STATUS_HINT = "CrustOutputStatusHint"
M.TOOL_PREFIX = "CrustToolPrefix"
M.TOOL_BACKGROUND = "CrustToolBackground"
M.TOOL_BODY_BACKGROUND = "CrustToolBodyBackground"
M.TOOL_ICON_PENDING = "CrustToolIconPending"
M.TOOL_ICON_SUCCESS = "CrustToolIconSuccess"
M.TOOL_ICON_ERROR = "CrustToolIconError"
M.WINBAR = "CrustWinbar"
M.WINBAR_TITLE = "CrustWinbarTitle"
M.MENTION = "CrustMention"

--- The 16 ansi colours of tool output, indexed 0-15 like the terminal palette.
---@type table<integer, string>
M.ANSI = {}
for index = 0, 15 do
	M.ANSI[index] = "CrustAnsi" .. index
end

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
	[M.STATUS] = { link = "Comment" },
	[M.STATUS_ICON] = { link = "Keyword" },
	[M.STATUS_TIME] = { link = "Comment" },
	[M.STATUS_HINT] = { link = "WarningMsg" },
	[M.TOOL_PREFIX] = { link = "Comment" },
	-- Code-block shading. RenderMarkdownCode comes from render-markdown.nvim;
	-- CursorLine is the fallback when that plugin is absent.
	[M.TOOL_BACKGROUND] = { link = "RenderMarkdownCode" },
	[M.TOOL_BODY_BACKGROUND] = { link = "RenderMarkdownCode" },
	[M.TOOL_ICON_PENDING] = { link = "DiagnosticWarn" },
	[M.TOOL_ICON_SUCCESS] = { link = "DiagnosticOk" },
	[M.TOOL_ICON_ERROR] = { link = "DiagnosticError" },
	[M.WINBAR] = { link = "WinBar" },
	[M.WINBAR_TITLE] = { link = "Title" },
	-- @mentions are blue: Directory is the blue every colorscheme defines,
	-- and `terminal_color_4` replaces it in `M.setup` when it is set.
	[M.MENTION] = { link = "Directory" },
}

-- Ansi colours follow the terminal palette, so they match the colorscheme.
-- `terminal_color_N` is resolved in `M.setup`, where it is up to date.
for index = 0, 15 do
	M.groups[M.ANSI[index]] = { ctermfg = index }
end

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

	local function define()
		for name, def in pairs(M.groups) do
			vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
		end
		for index = 0, 15 do
			local color = vim.g["terminal_color_" .. index]
			if type(color) == "string" and color ~= "" then
				vim.api.nvim_set_hl(0, M.ANSI[index], { fg = color, ctermfg = index, default = true })
			end
		end

		local blue = vim.g.terminal_color_4
		if type(blue) == "string" and blue ~= "" then
			vim.api.nvim_set_hl(0, M.MENTION, { fg = blue, ctermfg = 4, default = true })
		end
	end

	define()

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("crust.highlights", { clear = true }),
		callback = define,
	})
end

return M
