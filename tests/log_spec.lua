local Log = require("crust.log")
local config = require("crust.config")

---@param path string
---@return string[]
local function read_lines(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*a")
	file:close()
	return vim.split(vim.trim(content), "\n", { plain = true })
end

describe("log", function()
	local dir

	before_each(function()
		config.options = {}
		config.config = nil
		dir = vim.fn.tempname()
	end)

	after_each(function()
		vim.fn.delete(dir, "rf")
	end)

	it("defaults the directory to the nvim state dir", function()
		assert.are.equal(vim.fn.stdpath("state") .. "/crust", config.get().log.dir)
	end)

	it("names the file crust-<session>.log", function()
		local log = Log.new("my-session", dir)
		assert.are.equal(dir .. "/crust-my-session.log", log:path())
	end)

	it("uses a timestamped session name by default", function()
		local log = Log.new(nil, dir)
		assert.is_truthy(log:path():match("/crust%-%d+%-%d+%.log$"))
	end)

	it("sanitizes path separators out of the session name", function()
		local log = Log.new("../../etc/passwd", dir)
		assert.are.equal(dir .. "/crust-.._.._etc_passwd.log", log:path())
	end)

	it("creates the directory lazily on first write", function()
		local log = Log.new("s", dir)
		assert.are.equal(0, vim.fn.isdirectory(dir))
		log:sent("{}")
		assert.are.equal(1, vim.fn.isdirectory(dir))
		log:close()
	end)

	it("writes the raw json of sent and received lines", function()
		local log = Log.new("s", dir)
		log:sent('{"type":"prompt","message":"hi"}')
		log:received('{"type":"response","success":true}')
		log:close()

		local lines = read_lines(log:path())
		assert.are.equal(2, #lines)
		assert.is_truthy(lines[1]:match('^{"type":"prompt","message":"hi"} '))
		assert.is_truthy(lines[2]:match('^{"type":"response","success":true} '))
	end)

	it("ends every line with a millisecond timestamp", function()
		local log = Log.new("s", dir)
		log:sent("{}")
		log:close()

		local line = read_lines(log:path())[1]
		assert.is_truthy(line:match("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%d$"))
	end)

	it("appends across reopens instead of truncating", function()
		local first = Log.new("s", dir)
		first:sent("{}")
		first:close()

		local second = Log.new("s", dir)
		second:received("{}")
		second:close()

		assert.are.equal(2, #read_lines(first:path()))
	end)

	it("renames the file when pi reports its session id", function()
		local log = Log.new("temp", dir)
		log:sent("{}")
		local old_path = log:path()

		log:set_session("real-session")
		log:received("{}")
		log:close()

		assert.are.equal(dir .. "/crust-real-session.log", log:path())
		assert.are.equal(0, vim.fn.filereadable(old_path))
		assert.are.equal(2, #read_lines(log:path()))
	end)

	it("is a no-op when the session name does not change", function()
		local log = Log.new("same", dir)
		log:sent("{}")
		log:set_session("same")
		log:received("{}")
		log:close()

		assert.are.equal(2, #read_lines(log:path()))
	end)
end)

describe("pi client logging", function()
	local dir

	before_each(function()
		dir = vim.fn.tempname()
		config.options = { log = { enabled = true, dir = dir } }
		config.config = nil
	end)

	after_each(function()
		vim.fn.delete(dir, "rf")
	end)

	it("creates a log by default", function()
		local pi = require("crust.pi.client").new()
		assert.is_not_nil(pi:log())
		assert.is_truthy(pi:log():path():find(dir, 1, true))
	end)

	it("accepts a session name", function()
		local pi = require("crust.pi.client").new({ log = "named" })
		assert.are.equal(dir .. "/crust-named.log", pi:log():path())
	end)

	it("can be disabled per client", function()
		local pi = require("crust.pi.client").new({ log = false })
		assert.is_nil(pi:log())
	end)

	it("can be disabled globally", function()
		config.options = { log = { dir = dir, enabled = false } }
		config.config = nil
		local pi = require("crust.pi.client").new()
		assert.is_nil(pi:log())
	end)
end)
