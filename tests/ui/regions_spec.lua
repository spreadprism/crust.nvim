local Regions = require("crust.ui.regions")

describe("ui.regions", function()
	describe("complement", function()
		it("returns the whole buffer when nothing is excluded", function()
			assert.are.same({ { first = 0, last = 10 } }, Regions.complement(10, {}))
		end)

		it("splits around one excluded range", function()
			assert.are.same({
				{ first = 0, last = 3 },
				{ first = 6, last = 10 },
			}, Regions.complement(10, { { first = 3, last = 6 } }))
		end)

		it("handles a range at the start", function()
			assert.are.same({ { first = 3, last = 10 } }, Regions.complement(10, { { first = 0, last = 3 } }))
		end)

		it("handles a range at the end", function()
			assert.are.same({ { first = 0, last = 7 } }, Regions.complement(10, { { first = 7, last = 10 } }))
		end)

		it("sorts unordered ranges", function()
			assert.are.same({
				{ first = 0, last = 2 },
				{ first = 4, last = 6 },
				{ first = 8, last = 10 },
			}, Regions.complement(10, { { first = 6, last = 8 }, { first = 2, last = 4 } }))
		end)

		it("merges overlapping ranges", function()
			assert.are.same({
				{ first = 0, last = 2 },
				{ first = 7, last = 10 },
			}, Regions.complement(10, { { first = 2, last = 5 }, { first = 4, last = 7 } }))
		end)

		it("returns nothing when everything is excluded", function()
			assert.are.same({}, Regions.complement(10, { { first = 0, last = 10 } }))
		end)
	end)

	describe("exclude", function()
		---@return integer buf
		local function markdown_buf(lines)
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].filetype = "markdown"
			vim.treesitter.start(buf, "markdown")
			return buf
		end

		---@param buf integer
		---@return integer[] rows of heading captures
		local function heading_rows(buf)
			local parser = vim.treesitter.get_parser(buf)
			local query = vim.treesitter.query.get("markdown", "highlights")
			local rows = {}
			for _, tree in ipairs(parser:parse(true)) do
				for id, node in query:iter_captures(tree:root(), buf) do
					if query.captures[id]:match("heading") then
						rows[#rows + 1] = (node:range())
					end
				end
			end
			return rows
		end

		it("hides excluded rows from the parser", function()
			local buf = markdown_buf({ "# one", "", "# hidden", "", "# two" })
			assert.are.same({ 0, 2, 4 }, heading_rows(buf))

			assert.is_true(Regions.exclude(buf, { { first = 2, last = 3 } }))
			assert.are.same({ 0, 4 }, heading_rows(buf))
		end)

		it("restores rows when the exclusion is dropped", function()
			local buf = markdown_buf({ "# one", "# hidden", "# two" })
			Regions.exclude(buf, { { first = 1, last = 2 } })
			assert.are.same({ 0, 2 }, heading_rows(buf))

			Regions.exclude(buf, {})
			assert.are.same({ 0, 1, 2 }, heading_rows(buf))
		end)

		it("survives excluding the whole buffer", function()
			local buf = markdown_buf({ "# one" })
			assert.is_true(Regions.exclude(buf, { { first = 0, last = 1 } }))
			assert.are.same({}, heading_rows(buf))
		end)

		it("reports when the buffer has no parser", function()
			local buf = vim.api.nvim_create_buf(false, true)
			assert.is_false(Regions.exclude(buf, {}))
		end)

		it("ignores an invalid buffer", function()
			assert.is_false(Regions.exclude(123456, {}))
		end)
	end)
end)
