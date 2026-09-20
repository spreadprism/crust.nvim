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

		it("stops at MAX_ITEMS instead of building the whole tree", function()
			local paths = {}
			for index = 1, Completion.MAX_ITEMS * 3 do
				paths[index] = "file" .. index .. ".lua"
			end
			stub_files(paths)

			assert.are.equal(Completion.MAX_ITEMS, #Completion.complete_files("", item))
			assert.are.equal(Completion.MAX_ITEMS, #Completion.complete_files("file", item))
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

describe("completion.files", function()
	local dir

	before_each(function()
		Files.invalidate()
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir .. "/lua/crust", "p")
		vim.fn.writefile({ "" }, dir .. "/README.md")
		vim.fn.writefile({ "" }, dir .. "/lua/crust/init.lua")
	end)

	after_each(function()
		Files.invalidate()
		vim.fn.delete(dir, "rf")
	end)

	---@param cwd string
	---@return string[]
	local function scan(cwd)
		local files
		Files.ensure(cwd, function(result)
			files = result
		end)
		vim.wait(5000, function()
			return files ~= nil
		end, 10)
		return assert(files, "the scan never finished")
	end

	it("answers instantly with an empty list before the first scan", function()
		local started = vim.uv.hrtime()
		assert.are.same({}, Files.list(dir))
		-- No process may be waited on here: 50ms is orders of magnitude more
		-- than a table lookup and far below a `git ls-files`.
		assert.is_true((vim.uv.hrtime() - started) < 50e6)
	end)

	it("fills the cache in the background", function()
		local files = scan(dir)
		assert.is_true(vim.tbl_contains(files, "README.md"))
		assert.is_true(vim.tbl_contains(files, "lua/crust/init.lua"))
		assert.are.same(files, Files.list(dir))
	end)

	it("reuses a fresh listing without rescanning", function()
		scan(dir)
		vim.fn.writefile({ "" }, dir .. "/late.md")

		assert.is_false(vim.tbl_contains(scan(dir), "late.md"))
	end)

	it("walks the tree when no lister is installed", function()
		local commands = Files.commands
		Files.commands = function()
			return {}
		end

		local files = scan(dir)
		Files.commands = commands

		assert.is_true(vim.tbl_contains(files, "README.md"))
		assert.is_true(vim.tbl_contains(files, "lua/crust/init.lua"))
	end)

	it("falls back to the built-in listers without snacks", function()
		-- snacks.nvim is not installed in the test runtime, so its command
		-- lookup must not leak into the list.
		assert.are.same(Files.COMMANDS, Files.commands())
	end)

	it("fills the cache while the scan is still running", function()
		local commands = Files.commands
		-- One path per line, with a pause in the middle, so the first chunk
		-- has to be visible before the process exits.
		Files.commands = function()
			return { { "sh", "-c", "printf 'early.lua\\n'; sleep 0.4; printf 'late.lua\\n'" } }
		end

		local done = false
		Files.ensure(dir, function()
			done = true
		end)

		-- Partial results are readable long before the callback fires.
		vim.wait(2000, function()
			return #Files.list(dir) > 0
		end, 10)
		assert.are.same({ "early.lua" }, Files.list(dir))
		assert.is_false(done)
		assert.is_true(Files.scanning(dir))

		vim.wait(5000, function()
			return done
		end, 10)
		Files.commands = commands

		assert.are.same({ "early.lua", "late.lua" }, Files.list(dir))
		assert.is_false(Files.scanning(dir))
	end)

	it("joins a path split across two chunks", function()
		local commands = Files.commands
		Files.commands = function()
			return { { "sh", "-c", "printf 'lua/cru'; sleep 0.3; printf 'st/init.lua\\n'" } }
		end

		local files = scan(dir)
		Files.commands = commands

		assert.are.same({ "lua/crust/init.lua" }, files)
	end)

	it("keeps a last line without a trailing newline", function()
		local commands = Files.commands
		Files.commands = function()
			return { { "sh", "-c", "printf 'a.lua\\nb.lua'" } }
		end

		local files = scan(dir)
		Files.commands = commands

		assert.are.same({ "a.lua", "b.lua" }, files)
	end)

	it("falls through to the next lister when one fails", function()
		local commands = Files.commands
		Files.commands = function()
			return {
				{ "sh", "-c", "exit 2" },
				{ "sh", "-c", "printf 'fallback.lua\\n'" },
			}
		end

		local files = scan(dir)
		Files.commands = commands

		assert.are.same({ "fallback.lua" }, files)
	end)

	it("caps the listing at MAX_FILES", function()
		local max = Files.MAX_FILES
		Files.MAX_FILES = 1

		local files = scan(dir)
		Files.MAX_FILES = max

		assert.are.equal(1, #files)
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
	local list, commands, ensure

	---@type fun(files: string[])[]
	local pending

	before_each(function()
		list, commands, ensure = Files.list, Commands.list, Files.ensure
		pending = {}
		-- No scan in the tests: the waiting callbacks are released by hand.
		Files.ensure = function(_, callback)
			if callback then
				pending[#pending + 1] = callback
			end
		end
	end)

	after_each(function()
		Files.list, Commands.list, Files.ensure = list, commands, ensure
	end)

	---@param line string
	---@param row? integer
	---@return table[] items, integer answers
	local function complete_all(line, row)
		local source = require("crust.completion.blink").new()
		local items, answers = nil, 0
		source:get_completions({ line = line, cursor = { row or 1, #line } }, function(response)
			answers = answers + 1
			items = response.items
		end)
		return items, answers
	end

	---@param line string
	---@param row? integer
	---@return table[]
	local function complete(line, row)
		local items = complete_all(line, row)
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

	it("answers exactly once when the cache has paths", function()
		-- blink appends the items of every callback, so a second answer would
		-- show each path twice.
		stub_files({ "lua/crust/init.lua" })

		local items, answers = complete_all("@lua")
		assert.are.equal(1, answers)
		assert.are.equal(1, #items)

		for _, callback in ipairs(pending) do
			callback({ "lua/crust/init.lua" })
		end
		assert.are.equal(1, answers)
	end)

	it("waits for the first scan when nothing is cached", function()
		stub_files({})

		local source = require("crust.completion.blink").new()
		local items, answers = nil, 0
		source:get_completions({ line = "@lua", cursor = { 1, 4 } }, function(response)
			answers = answers + 1
			items = response.items
		end)

		assert.are.equal(0, answers)

		stub_files({ "lua/crust/init.lua" })
		for _, callback in ipairs(pending) do
			callback({ "lua/crust/init.lua" })
		end

		assert.are.equal(1, answers)
		-- The prefix stops at the first separator, so the directory is offered.
		assert.are.equal("@lua/", items[1].label)
	end)

	it("drops the late answer of a cancelled request", function()
		stub_files({})

		local source = require("crust.completion.blink").new()
		local answers = 0
		local cancel = source:get_completions({ line = "@lua", cursor = { 1, 4 } }, function()
			answers = answers + 1
		end)

		cancel()
		stub_files({ "lua/crust/init.lua" })
		for _, callback in ipairs(pending) do
			callback({ "lua/crust/init.lua" })
		end

		assert.are.equal(0, answers)
	end)
end)
