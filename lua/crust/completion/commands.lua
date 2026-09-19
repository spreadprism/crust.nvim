--- Slash commands behind `/` completion.
---
--- pi answers `get_commands` with the extensions, prompts and skills of the
--- session. The list barely changes, so it is fetched once per process and
--- refreshed when the session does.

---@class Crust.Completion.Commands
local M = {}

local Command = require("crust.pi.rpc")

---@type Crust.Pi.CommandInfo[]
local commands = {}

---@type boolean true while a `get_commands` is in flight
local fetching = false

--- The commands known right now, without asking pi.
---@return Crust.Pi.CommandInfo[]
function M.list()
	return commands
end

--- Ask pi for its commands, at most one request at a time.
---@param pi Crust.Pi?
---@param callback? fun(commands: Crust.Pi.CommandInfo[])
function M.fetch(pi, callback)
	if not pi or not pi:is_running() or fetching then
		if callback then
			callback(commands)
		end
		return
	end

	fetching = true
	local _, err = pi:send(Command.get_commands(), function(event)
		fetching = false

		local data = event.success ~= false and event.data or nil --[[@as Crust.Pi.Data.Commands?]]
		if data and type(data.commands) == "table" then
			commands = data.commands
		end
		if callback then
			callback(commands)
		end
	end)

	if err then
		fetching = false
		if callback then
			callback(commands)
		end
	end
end

--- Forget the cached commands, e.g. when the session changes.
function M.invalidate()
	commands = {}
end

return M
