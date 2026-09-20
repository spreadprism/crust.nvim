--- Model picker.
---
--- Uses snacks.nvim when it is installed, as a plain list of models with
--- their `provider/id` next to the display name, and falls back to
--- `vim.ui.select`.

local M = {}

local Models = require("crust.models")
local Highlights = require("crust.ui.highlights")

---@class Crust.Models.Picker.Opts
---@field title? string picker title
---@field current? string `provider/id` of the live model, marked in the list

---@param model Crust.Pi.Model
---@return snacks.picker.finder.Item
local function item(model)
	return { model = model, text = Models.label(model) }
end

---@param models Crust.Pi.Model[]
---@param opts Crust.Models.Picker.Opts
---@param on_choice fun(model: Crust.Pi.Model?)
local function snacks_pick(models, opts, on_choice)
	require("snacks").picker.pick({
		source = "crust_models",
		title = opts.title or "Crust models",
		items = vim.tbl_map(item, models),
		-- Names are all we show, like the session picker: no preview window.
		preview = "none",
		layout = { preset = "select" },
		format = function(entry)
			local model = entry.model --[[@as Crust.Pi.Model]]
			local live = opts.current == Models.spec(model)
			return {
				{ live and "● " or "  ", Highlights.AGENT_TITLE },
				{ model.name or model.id, Highlights.USER_TITLE },
				{ "  " .. Models.spec(model), Highlights.TIMESTAMP },
			}
		end,
		confirm = function(picker, entry)
			picker:close()
			on_choice(entry and entry.model or nil)
		end,
	})
end

---@param models Crust.Pi.Model[]
---@param opts Crust.Models.Picker.Opts
---@param on_choice fun(model: Crust.Pi.Model?)
local function ui_select(models, opts, on_choice)
	vim.ui.select(models, {
		prompt = opts.title or "Crust models",
		kind = "crust-models",
		format_item = Models.label,
	}, on_choice)
end

--- Pick one of `models`. `<CR>` selects it.
---@param models Crust.Pi.Model[]
---@param opts? Crust.Models.Picker.Opts
---@param on_choice fun(model: Crust.Pi.Model?) called with nil when cancelled
function M.select(models, opts, on_choice)
	opts = opts or {}

	if #models == 0 then
		on_choice(nil)
		return
	end

	if M.has_snacks() then
		snacks_pick(models, opts, on_choice)
	else
		ui_select(models, opts, on_choice)
	end
end

---@return boolean
function M.has_snacks()
	local ok, snacks = pcall(require, "snacks")
	return ok and type(snacks) == "table" and snacks.picker ~= nil
end

return M
