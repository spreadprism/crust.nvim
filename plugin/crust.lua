if vim.g.loaded_crust then
	return
end
vim.g.loaded_crust = true

---@type table<string, fun(args: string[], opts: table)>
local subcommands = {
	chat = function()
		require("crust").open()
	end,
	toggle = function()
		require("crust").toggle()
	end,
	stop = function()
		require("crust").stop()
	end,
	continue = function()
		require("crust").continue()
	end,
	new = function()
		require("crust").new_session()
	end,
	sessions = function()
		require("crust").sessions()
	end,
	last = function()
		require("crust").session_last()
	end,
	-- `:'<,'>Crust send` hands the range over; without one the current file
	-- (or oil directory) is sent whole.
	send = function(_, opts)
		require("crust").send(opts.range > 0 and { first = opts.line1, last = opts.line2 } or { visual = false })
	end,
	rename = function(args)
		local name = table.concat(args, " ")
		require("crust").rename_session(name ~= "" and name or nil)
	end,
}

local names = vim.tbl_keys(subcommands)
table.sort(names)

vim.api.nvim_create_user_command("Crust", function(opts)
	local args = vim.list_slice(opts.fargs, 2)
	local run = subcommands[opts.fargs[1] or "chat"]

	if not run then
		vim.notify("crust: unknown subcommand '" .. opts.fargs[1] .. "'", vim.log.levels.ERROR)
		return
	end

	run(args, opts)
end, {
	nargs = "*",
	range = true,
	desc = "crust chat",
	complete = function(lead, line)
		-- Only the first argument is a subcommand, the rest is free text.
		if line:match("^%s*%S+%s+%S*$") == nil then
			return {}
		end
		return vim.tbl_filter(function(name)
			return name:find(lead, 1, true) == 1
		end, names)
	end,
})
