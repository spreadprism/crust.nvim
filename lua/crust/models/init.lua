--- The models pi was configured with.
---
--- `get_available_models` is answered per process, so the list is fetched
--- from the running instance and matched against whatever the user typed:
--- `provider/id`, a bare id, or the display name.

---@class Crust.Models
local M = {}

local Command = require("crust.pi.rpc")

--- Ask pi for the models it can switch to.
---@param pi Crust.Pi?
---@param callback fun(models: Crust.Pi.Model[], err: string?)
function M.fetch(pi, callback)
	if not pi or not pi:is_running() then
		callback({}, "pi process is not running")
		return
	end

	local _, err = pi:send(Command.get_available_models(), function(event)
		if event.success == false then
			callback({}, event.error or "failed to list models")
			return
		end

		local data = event.data --[[@as Crust.Pi.Data.Models?]]
		callback(data and data.models or {}, nil)
	end)

	if err then
		callback({}, err)
	end
end

--- `provider/id`, how a model is written on pi's command line.
---@param model Crust.Pi.Model
---@return string
function M.spec(model)
	return model.provider .. "/" .. model.id
end

--- `Claude Sonnet 4  anthropic/claude-sonnet-4`, for pickers.
---@param model Crust.Pi.Model
---@return string
function M.label(model)
	local spec = M.spec(model)
	if model.name and model.name ~= "" and model.name ~= model.id then
		return model.name .. "  " .. spec
	end
	return spec
end

---@param value string
---@return string
local function normalize(value)
	return (value:lower():gsub("%s+", ""))
end

--- Find the model `query` names.
---
--- Matching goes from the most explicit form down: `provider/id`, then the
--- id on its own, then the display name, then anything containing it, so
--- `haiku` picks the only haiku that is configured but stays ambiguous
--- (nil) when several match.
---@param models Crust.Pi.Model[]
---@param query string
---@return Crust.Pi.Model? model
---@return string? err
function M.resolve(models, query)
	local wanted = normalize(query)
	if wanted == "" then
		return nil, "no model given"
	end

	---@type Crust.Pi.Model[]
	local partial = {}

	for _, model in ipairs(models) do
		if normalize(M.spec(model)) == wanted then
			return model
		end
		if normalize(model.id) == wanted or normalize(model.name or "") == wanted then
			return model
		end
		if normalize(M.spec(model)):find(wanted, 1, true) or normalize(model.name or ""):find(wanted, 1, true) then
			partial[#partial + 1] = model
		end
	end

	if #partial == 1 then
		return partial[1]
	end

	if #partial > 1 then
		local specs = vim.tbl_map(M.spec, partial)
		return nil, "'" .. query .. "' matches " .. #partial .. " models: " .. table.concat(specs, ", ")
	end

	return nil, "unknown model '" .. query .. "'"
end

return M
