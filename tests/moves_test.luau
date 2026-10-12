--!strict
local Diff = require("../src/diff")
local Moves = require("../src/moves")
local Pr = require("../src/pr")

local function file(path: string, rows: { Pr.Row }): Pr.File
	return { path = path, status = "modified", adds = 0, dels = 0, rows = rows }
end

local function hunk(oldStart: number, newStart: number): Pr.Row
	local row: Pr.Hunk = { kind = "hunk", oldStart = oldStart, newStart = newStart }
	return row
end

local function ctx(text: string, old: number, new: number): Pr.Row
	return { kind = "ctx", text = text, old = old, new = new }
end

-- Removed rows for `lines`, the first at old line `first`.
local function dels(first: number, lines: { string }): { Pr.Row }
	local rows: { Pr.Row } = {}
	for k, text in lines do
		local row: Pr.Line = { kind = "del", text = text, old = first + k - 1 }
		table.insert(rows, row)
	end
	return rows
end

local function adds(first: number, lines: { string }): { Pr.Row }
	local rows: { Pr.Row } = {}
	for k, text in lines do
		local row: Pr.Line = { kind = "add", text = text, new = first + k - 1 }
		table.insert(rows, row)
	end
	return rows
end

local function cat(...: { Pr.Row }): { Pr.Row }
	local out: { Pr.Row } = {}
	for _, part in { ... } do
		for _, row in part do table.insert(out, row) end
	end
	return out
end

local function indented(lines: { string }, by: string): { string }
	local out = {}
	for _, text in lines do table.insert(out, if text == "" then text else by .. text) end
	return out
end

-- The row index of the first row with this text and kind.
local function rowOf(f: Pr.File, kind: string, text: string): number
	for index, row in f.rows do
		if row.kind == kind and (row :: Pr.Line).text == text then return index end
	end
	error("no " .. kind .. " row " .. text)
end

local function movedRows(moves: Moves.Moves, path: string): number
	local n = 0
	for _ in moves[path] or {} do n += 1 end
	return n
end

local PARSE = {
	"function parseHeader(input: string): Header {",
	"  const parts = input.split(':')",
	"  if (parts.length < 2) throw new Error('bad header')",
	"  return { name: parts[0].trim(), value: parts[1].trim() }",
	"}",
}

return function()
	-- a function cut from one file and pasted in another matches both ways, line by line
	do
		local a = file("src/a.ts", cat({ hunk(8, 8) }, { ctx("// helpers", 8, 8) }, dels(10, PARSE), { ctx("export {}", 15, 10) }))
		local b = file("src/b.ts", cat({ hunk(38, 38) }, { ctx("// parsing", 38, 38) }, adds(40, PARSE), { ctx("export {}", 39, 45) }))
		local moves = Moves.detect({ a, b })
		local first = rowOf(a, "del", PARSE[1])
		for k = 0, 4 do
			local from = moves["src/a.ts"][first + k]
			assert(from and from.path == "src/b.ts" and from.line == 40 + k, "removed line " .. k .. " points at its new line")
			assert(from.start == (k == 0), "only the first removed line starts the block")
		end
		local second = rowOf(b, "add", PARSE[1])
		for k = 0, 4 do
			local to = moves["src/b.ts"][second + k]
			assert(to and to.path == "src/a.ts" and to.line == 10 + k, "added line " .. k .. " points at its old line")
			assert(to.start == (k == 0), "only the first added line starts the block")
		end
		assert(movedRows(moves, "src/a.ts") == 5 and movedRows(moves, "src/b.ts") == 5)
		assert(moves["src/a.ts"][first - 1] == nil and moves["src/a.ts"][first + 5] == nil, "context around a move is not moved")
	end

	-- a different indentation still matches
	do
		local a = file("a.ts", cat({ hunk(1, 1) }, dels(1, PARSE)))
		local b = file("b.ts", cat({ hunk(1, 1) }, adds(20, indented(PARSE, "    "))))
		local moves = Moves.detect({ a, b })
		assert(movedRows(moves, "a.ts") == 5 and movedRows(moves, "b.ts") == 5)
		assert(moves["b.ts"][rowOf(b, "add", "    " .. PARSE[1])].line == 1)
	end

	-- a 2-line coincidence is not a move
	do
		local two = { PARSE[1], PARSE[2] }
		local moves = Moves.detect({ file("a.ts", cat({ hunk(1, 1) }, dels(1, two))), file("b.ts", cat({ hunk(1, 1) }, adds(1, two))) })
		assert(next(moves) == nil)
	end

	-- a block of only braces and closers is not a move, nor is a short one
	do
		local braces = { "}", "  }", "});", "end", "end)" }
		local moves = Moves.detect({ file("a.ts", cat({ hunk(1, 1) }, dels(1, braces))), file("b.ts", cat({ hunk(1, 1) }, adds(1, braces))) })
		assert(next(moves) == nil)
		local short = { "a();", "b();", "c();" }
		moves = Moves.detect({ file("a.ts", cat({ hunk(1, 1) }, dels(1, short))), file("b.ts", cat({ hunk(1, 1) }, adds(1, short))) })
		assert(next(moves) == nil)
	end

	-- a block moved within one file
	do
		local f = file("src/a.ts", cat(
			{ hunk(1, 1) },
			dels(5, PARSE),
			{ ctx("const x = 1", 10, 5), ctx("const y = 2", 11, 6), ctx("const z = 3", 12, 7) },
			adds(8, PARSE)
		))
		local moves = Moves.detect({ f })
		local first = rowOf(f, "del", PARSE[1])
		assert(moves["src/a.ts"][first].path == "src/a.ts" and moves["src/a.ts"][first].line == 8 and moves["src/a.ts"][first].start)
		local added = rowOf(f, "add", PARSE[1])
		assert(moves["src/a.ts"][added].path == "src/a.ts" and moves["src/a.ts"][added].line == 5 and moves["src/a.ts"][added].start)
		assert(movedRows(moves, "src/a.ts") == 10)
	end

	-- removed lines and the added lines right after them are one change group, not a move
	do
		local f = file("a.ts", cat({ hunk(1, 1) }, dels(1, PARSE), adds(1, indented(PARSE, "  "))))
		assert(next(Moves.detect({ f })) == nil)
	end

	-- one edited line in the middle splits a block in two; halves that are long enough stay moved
	-- and the edited lines stay an ordinary change
	do
		local long = {
			"const config = loadConfig(path)",
			"const token = config.auth.token",
			"const client = new Client(token)",
			"client.retries = config.retries",
			"await client.connect(config.host)",
			"await client.subscribe(config.topic)",
			"return client",
		}
		local edited = table.clone(long)
		edited[4] = "client.retries = config.retries + 1"
		local a = file("a.ts", cat({ hunk(1, 1) }, dels(1, long)))
		local b = file("b.ts", cat({ hunk(1, 1) }, adds(30, edited)))
		local moves = Moves.detect({ a, b })
		assert(movedRows(moves, "a.ts") == 6 and movedRows(moves, "b.ts") == 6)
		assert(moves["a.ts"][rowOf(a, "del", long[1])].start and moves["a.ts"][rowOf(a, "del", long[5])].start)
		assert(moves["a.ts"][rowOf(a, "del", long[4])] == nil and moves["b.ts"][rowOf(b, "add", edited[4])] == nil)
		assert(moves["b.ts"][rowOf(b, "add", long[5])].line == 5)

		-- with halves of two lines each nothing is long enough
		local five = { long[1], long[2], long[3], long[4], long[5] }
		local five2 = table.clone(five)
		five2[3] = "const client = new Client(token, true)"
		moves = Moves.detect({ file("a.ts", cat({ hunk(1, 1) }, dels(1, five))), file("b.ts", cat({ hunk(1, 1) }, adds(1, five2))) })
		assert(next(moves) == nil)
	end

	-- blank lines don't break a block, and the blank rows inside it are moved too
	do
		local spaced = { PARSE[1], PARSE[2], "", PARSE[3], PARSE[4], PARSE[5] }
		local a = file("a.ts", cat({ hunk(1, 1) }, dels(1, spaced)))
		local b = file("b.ts", cat({ hunk(1, 1) }, adds(1, { PARSE[1], PARSE[2], PARSE[3], PARSE[4], PARSE[5], "" })))
		local moves = Moves.detect({ a, b })
		assert(movedRows(moves, "a.ts") == 6, "the blank row inside the removed block is moved")
		assert(movedRows(moves, "b.ts") == 5, "a trailing blank row is not")
		assert(moves["a.ts"][4].start == false)
	end

	-- the same block removed in two places matches the added copy once
	do
		local a = file("a.ts", cat({ hunk(1, 1) }, dels(1, PARSE)))
		local b = file("b.ts", cat({ hunk(1, 1) }, dels(1, PARSE)))
		local c = file("c.ts", cat({ hunk(1, 1) }, adds(1, PARSE)))
		local moves = Moves.detect({ a, b, c })
		assert(movedRows(moves, "c.ts") == 5)
		assert(movedRows(moves, "a.ts") + movedRows(moves, "b.ts") == 5)
	end

	-- Diff.analyze: moved entries carry the move and no word-diff span; other lines are unchanged
	do
		local a = file("src/a.ts", cat(
			{ hunk(1, 1) },
			dels(1, PARSE),
			{ ctx("export {}", 6, 1) },
			dels(7, { "const a = 1;" }),
			adds(2, { "const a = 2;" })
		))
		local b = file("src/b.ts", cat({ hunk(1, 1) }, adds(1, PARSE)))
		local moves = Moves.detect({ a, b })
		local fd = Diff.analyze(a, moves["src/a.ts"])
		local head = fd.entries[1].moved :: Diff.Move
		assert(head.start and head.path == "src/b.ts")
		assert(fd.entries[1].changed == nil and fd.entries[5].moved ~= nil)
		assert(fd.entries[6].moved == nil and fd.entries[7].moved == nil)
		assert(fd.entries[7].changed ~= nil and fd.entries[8].changed ~= nil, "the unmoved pair keeps its word diff")
		assert(Diff.analyze(a, nil).entries[1].moved == nil)
	end

	-- a few thousand lines: unique blocks reordered across files, and one line repeated thousands of times
	do
		local removed: { Pr.Row } = { hunk(1, 1) }
		local added: { Pr.Row } = { hunk(1, 1) }
		local blocks = 300
		for n = 1, blocks do
			local lines = {}
			for k = 1, 10 do table.insert(lines, "local value_" .. n .. "_" .. k .. " = compute(" .. n .. ", " .. k .. ")") end
			for _, row in dels((n - 1) * 11 + 1, lines) do table.insert(removed, row) end
			table.insert(removed, ctx("-- separator " .. n, n * 11, n * 11))
			for _, row in adds((blocks - n) * 11 + 1, lines) do table.insert(added, row) end
			table.insert(added, ctx("-- separator " .. n, n * 11, n * 11))
		end
		local started = os.clock()
		local moves = Moves.detect({ file("a.ts", removed), file("b.ts", added) })
		assert(movedRows(moves, "a.ts") == 3000 and movedRows(moves, "b.ts") == 3000)
		assert(os.clock() - started < 2, "3000 moved lines match in well under two seconds")

		local same: { string } = {}
		for _ = 1, 3000 do table.insert(same, "  retry(attempt, backoff);") end
		started = os.clock()
		local rows = cat({ hunk(1, 1) }, dels(1, same), { ctx("-- between", 3001, 1) }, adds(2, same))
		moves = Moves.detect({ file("c.ts", rows) })
		assert(movedRows(moves, "c.ts") == 6000)
		assert(os.clock() - started < 2, "a repeated line doesn't go quadratic")
	end
end
