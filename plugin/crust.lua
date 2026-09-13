if vim.g.loaded_crust then
	return
end
vim.g.loaded_crust = true

local subcommands = { "chat", "toggle", "stop" }

vim.api.nvim_create_user_command("Crust", function(opts)
	local sub = opts.fargs[1] or "chat"
	local crust = require("crust")

	if sub == "chat" then
		crust.open()
	elseif sub == "toggle" then
		crust.toggle()
	elseif sub == "stop" then
		crust.stop()
	else
		vim.notify("crust: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
	end
end, {
	nargs = "?",
	desc = "crust chat",
	complete = function(lead)
		return vim.tbl_filter(function(name)
			return name:find(lead, 1, true) == 1
		end, subcommands)
	end,
})
