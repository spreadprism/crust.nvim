local Completion = require("crust.completion")
local Files = require("crust.completion.files")
local Commands = require("crust.completion.commands")
local Omnifunc = require("crust.completion.omnifunc")

---@param paths string[]
local function stub_files(paths)
	Files.list = function()
		return paths
	end
end

---@param list Crust.Pi.CommandInfo[]
local function stub_commands(list)
	Commands.list = function()
		return list
	end
end

describe("completion", function()
	local list, commands

	before_each(function()
		list, commands = Files.list, Commands.list
	end)

	after_each(function()
		Files.list, Commands.list = list, commands
	end)

	describe("context", function()
		it("finds a mention prefix behind the cursor", function()
			local ctx = assert(Completion.context("look at @lua/cru", 16, 3))
			assert.are.equal("file", ctx.kind)
			assert.are.equal("lua/cru", ctx.prefix)
			assert.are.equal(8, ctx.col)
		end)

		it("stops at a space, so prose is not a mention", function()
			assert.is_nil(Completion.context("@done now what", 14, 1))
		end)

		it("only takes a slash command on the first column of the first line", function()
			local ctx = assert(Completion.context("/comp", 5, 1))
			assert.are.equal("command", ctx.kind)
			assert.are.equal("comp", ctx.prefix)
			assert.are.equal(0, ctx.col)

			assert.is_nil(Completion.context("/comp", 5, 2))
			assert.is_nil(Completion.context(" /comp", 6, 1))
		end)

		it("is nil without a trigger", function()
			assert.is_nil(Completion.context("plain text", 10, 1))
		end)
	end)

	describe("fuzzy_match", function()
		it("matches characters in order, ignoring case", function()
			assert.is_true(Completion.fuzzy_match("lci", "lua/crust/init.lua"))
			assert.is_true(Completion.fuzzy_match("INIT", "lua/crust/init.lua"))
			assert.is_false(Completion.fuzzy_match("zzz", "lua/crust/init.lua"))
		end)
	end)

	describe("complete_files", function()
		---@param path string
		---@param kind string
		---@param fuzzy boolean
		local function item(path, kind, fuzzy)
			return { path = path, kind = kind, fuzzy = fuzzy }
		end

		it("collapses directories into a single entry", function()
			stub_files({ "lua/crust/init.lua", "lua/crust/log.lua", "README.md" })

			local items = Completion.complete_files("lua/", item)
			assert.are.same({ { path = "lua/crust/", kind = "dir", fuzzy = false } }, items)
		end)

		it("keeps files of the matched directory", function()
			stub_files({ "lua/crust/init.lua", "lua/crust/log.lua" })

			local items = Completion.complete_files("lua/crust/", item)
			assert.are.equal(2, #items)
			assert.are.equal("lua/crust/init.lua", items[1].path)
			assert.are.equal("file", items[1].kind)
		end)

		it("appends fuzzy matches after the prefix ones", function()
			stub_files({ "lua/crust/log.lua", "tests/log_spec.lua" })

			local items = Completion.complete_files("log", item)
			assert.are.equal(2, #items)
			-- "log" is not a prefix of either path, so both are fuzzy hits.
			assert.is_true(items[1].fuzzy)
			assert.is_true(items[2].fuzzy)
		end)

		it("lists everything for an empty prefix", function()
			stub_files({ "README.md", "justfile" })
			assert.are.equal(2, #Completion.complete_files("", item))
		end)
	end)

	describe("complete_commands", function()
		---@param command Crust.Pi.CommandInfo
		---@param fuzzy boolean
		local function item(command, fuzzy)
			return { name = command.name, fuzzy = fuzzy }
		end

		before_each(function()
			stub_commands({
				{ name = "compact", source = "prompt" },
				{ name = "skill:worklog", source = "skill" },
				{ name = "init", source = "extension" },
			})
		end)

		it("prefers prefix matches", function()
			local items = Completion.complete_commands("com", item)
			assert.are.equal("compact", items[1].name)
			assert.is_false(items[1].fuzzy)
		end)

		it("matches a skill by its short name", function()
			local items = Completion.complete_commands("worklog", item)
			assert.are.equal("skill:worklog", items[1].name)
			assert.is_false(items[1].fuzzy)
		end)

		it("falls back to fuzzy matches", function()
			local items = Completion.complete_commands("cpt", item)
			assert.are.equal("compact", items[1].name)
			assert.is_true(items[1].fuzzy)
		end)

		it("lists everything for an empty prefix", function()
			assert.are.equal(3, #Completion.complete_commands("", item))
		end)
	end)
end)

describe("completion.omnifunc", function()
	local list, commands, buf

	before_each(function()
		list, commands = Files.list, Commands.list
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(buf)
	end)

	after_each(function()
		Files.list, Commands.list = list, commands
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	---@param line string
	local function type_line(line)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
		vim.api.nvim_win_set_cursor(0, { 1, #line })
	end

	it("returns the trigger column for findstart", function()
		type_line("see @lua/")
		assert.are.equal(4, Omnifunc.completefunc(1, ""))
	end)

	it("returns -3 when there is nothing to complete", function()
		type_line("plain text")
		assert.are.equal(-3, Omnifunc.completefunc(1, ""))
	end)

	it("completes mentions into completion items", function()
		stub_files({ "lua/crust/init.lua" })
		type_line("see @lua/crust/init.lua")

		local items = Omnifunc.completefunc(0, "@lua/crust/init.lua")
		assert.are.equal("@lua/crust/init.lua", items[1].word)
		assert.are.equal("file", items[1].kind)
	end)

	it("completes commands into completion items", function()
		stub_commands({ { name = "compact", source = "prompt", description = "shrink" } })
		type_line("/comp")

		local items = Omnifunc.completefunc(0, "/comp")
		assert.are.equal("/compact", items[1].word)
		assert.are.equal("shrink", items[1].menu)
	end)
end)

describe("completion.blink", function()
	local list, commands

	before_each(function()
		list, commands = Files.list, Commands.list
	end)

	after_each(function()
		Files.list, Commands.list = list, commands
	end)

	---@param line string
	---@param row? integer
	---@return table[]
	local function complete(line, row)
		local source = require("crust.completion.blink").new()
		local items
		source:get_completions({ line = line, cursor = { row or 1, #line } }, function(response)
			items = response.items
		end)
		return items
	end

	it("exposes the trigger characters", function()
		assert.are.same({ "@", "/", "." }, require("crust.completion.blink").new():get_trigger_characters())
	end)

	it("is disabled outside the input buffer", function()
		assert.is_false(require("crust.completion.blink").new():enabled())
	end)

	it("builds mention items with the file kind", function()
		stub_files({ "lua/crust/init.lua" })

		local items = complete("see @lua/crust/i", 2)
		assert.are.equal("@lua/crust/init.lua", items[1].label)
		assert.are.equal(vim.lsp.protocol.CompletionItemKind.File, items[1].kind)
		assert.are.equal("@lua/crust/init.lua", items[1].insertText)
	end)

	it("builds command items with the source kind", function()
		stub_commands({ { name = "skill:worklog", source = "skill", description = "log time" } })

		local items = complete("/work")
		assert.are.equal("/skill:worklog", items[1].label)
		assert.are.equal(vim.lsp.protocol.CompletionItemKind.Module, items[1].kind)
		assert.are.equal("log time", items[1].labelDetails.description)
	end)

	it("answers with nothing outside a trigger", function()
		assert.are.same({}, complete("plain text"))
	end)
end)
