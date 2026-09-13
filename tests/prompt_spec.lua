local Prompt = require("crust.prompt")
local config = require("crust.config")

describe("prompt", function()
	before_each(function()
		config.options = {}
		config.config = nil
	end)

	describe("resolve", function()
		it("accepts a string", function()
			assert.are.same({ "one" }, Prompt.resolve("one"))
		end)

		it("accepts a list", function()
			assert.are.same({ "one", "two" }, Prompt.resolve({ "one", "two" }))
		end)

		it("accepts a function returning either", function()
			assert.are.same({ "one" }, Prompt.resolve(function()
				return "one"
			end))
			assert.are.same({ "one", "two" }, Prompt.resolve(function()
				return { "one", "two" }
			end))
		end)

		it("drops nil and empty values", function()
			assert.are.same({}, Prompt.resolve(nil))
			assert.are.same({}, Prompt.resolve(""))
			assert.are.same({ "one" }, Prompt.resolve({ "one", "" }))
		end)
	end)

	describe("appends", function()
		it("includes crust's own block by default", function()
			assert.are.same({ Prompt.DEFAULT_APPEND }, Prompt.appends())
		end)

		it("concatenates crust's block with the user's", function()
			assert.are.same({ Prompt.DEFAULT_APPEND, "mine" }, Prompt.appends({ append = "mine" }))
		end)

		it("keeps the order of several user blocks", function()
			assert.are.same(
				{ Prompt.DEFAULT_APPEND, "a", "b" },
				Prompt.appends({ append = { "a", "b" } })
			)
		end)

		it("can drop crust's block", function()
			assert.are.same({ "mine" }, Prompt.appends({ append = "mine", include_defaults = false }))
		end)
	end)

	describe("args", function()
		it("passes nothing but the default append out of the box", function()
			assert.are.same({ "--append-system-prompt", Prompt.DEFAULT_APPEND }, Prompt.args())
		end)

		it("replaces the system prompt", function()
			local args = Prompt.args({ system_prompt = "be terse", include_defaults = false })
			assert.are.same({ "--system-prompt", "be terse" }, args)
		end)

		it("accepts a function for the system prompt", function()
			local args = Prompt.args({
				system_prompt = function()
					return "computed"
				end,
				include_defaults = false,
			})
			assert.are.same({ "--system-prompt", "computed" }, args)
		end)

		it("repeats --append-system-prompt for each block", function()
			local args = Prompt.args({ append = { "a", "b" }, include_defaults = false })
			assert.are.same({
				"--append-system-prompt",
				"a",
				"--append-system-prompt",
				"b",
			}, args)
		end)

		it("combines a replaced prompt with appended blocks", function()
			local args = Prompt.args({ system_prompt = "base", append = "extra", include_defaults = false })
			assert.are.same({
				"--system-prompt",
				"base",
				"--append-system-prompt",
				"extra",
			}, args)
		end)

		it("reads the config when no options are given", function()
			config.options = { prompt = { append = "from config", include_defaults = false } }
			config.config = nil
			assert.are.same({ "--append-system-prompt", "from config" }, Prompt.args())
		end)
	end)

	describe("context", function()
		local dir

		before_each(function()
			dir = vim.fn.tempname()
			vim.fn.mkdir(dir, "p")
		end)

		after_each(function()
			vim.fn.delete(dir, "rf")
		end)

		---@param name string
		---@return string path
		local function write(name, text)
			local path = dir .. "/" .. name
			vim.fn.writefile({ text }, path)
			return path
		end

		it("adds nothing by default, pi keeps discovering context files", function()
			assert.are.same({}, Prompt.context_args())
		end)

		it("disables discovery when asked", function()
			assert.are.same({ "--no-context-files" }, Prompt.context_args({ enabled = false }))
		end)

		it("appends extra context files", function()
			local path = write("EXTRA.md", "extra")
			assert.are.same({ "--append-system-prompt", path }, Prompt.context_args({ files = path }))
		end)

		it("expands paths", function()
			local path = write("EXTRA.md", "extra")
			local args = Prompt.context_args({ files = { path } })
			assert.are.equal(vim.fn.fnamemodify(path, ":p"), args[2])
		end)

		it("skips files that do not exist", function()
			assert.are.same({}, Prompt.context_files({ files = dir .. "/missing.md" }))
		end)

		it("appends extra context lines after the files", function()
			local path = write("EXTRA.md", "extra")
			assert.are.same({
				"--append-system-prompt",
				path,
				"--append-system-prompt",
				"a line",
			}, Prompt.context_args({ files = path, append = "a line" }))
		end)

		it("accepts functions and lists", function()
			local args = Prompt.context_args({
				append = function()
					return { "one", "two" }
				end,
			})
			assert.are.same({
				"--append-system-prompt",
				"one",
				"--append-system-prompt",
				"two",
			}, args)
		end)

		it("reads the config when no options are given", function()
			config.options = { context = { enabled = false, append = "from config" } }
			config.config = nil
			assert.are.same({
				"--no-context-files",
				"--append-system-prompt",
				"from config",
			}, Prompt.context_args())
		end)
	end)

	describe("pi client", function()
		it("puts the prompt flags on the command line", function()
			config.options = { prompt = { system_prompt = "base", append = "extra", include_defaults = false } }
			config.config = nil

			local pi = require("crust.pi.client").new({ log = false })
			local cmd = table.concat(pi:_command(), " ")

			assert.is_truthy(cmd:find("--system-prompt base", 1, true))
			assert.is_truthy(cmd:find("--append-system-prompt extra", 1, true))
			assert.is_truthy(cmd:find("--mode rpc", 1, true))
		end)


		it("accepts a per-client prompt", function()
			local pi = require("crust.pi.client").new({
				log = false,
				prompt = { system_prompt = "just this", include_defaults = false },
			})
			assert.are.same({
				"pi",
				"--system-prompt",
				"just this",
				"--mode",
				"rpc",
			}, pi:_command())
		end)

		it("puts the context flags on the command line", function()
			local pi = require("crust.pi.client").new({
				log = false,
				prompt = { include_defaults = false },
				context = { append = "extra context" },
			})
			assert.are.same({
				"pi",
				"--append-system-prompt",
				"extra context",
				"--mode",
				"rpc",
			}, pi:_command())
		end)

		it("leaves pi's context discovery alone by default", function()
			local cmd = table.concat(require("crust.pi.client").new({ log = false }):_command(), " ")
			assert.is_falsy(cmd:find("--no-context-files", 1, true))
		end)
	end)
end)
