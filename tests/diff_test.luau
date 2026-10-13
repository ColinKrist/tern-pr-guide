--!strict
local Diff = require("../src/diff")
local Pr = require("../src/pr")

-- A file of `lines` where each line in `added` is an added line and the rest of the lines within three
-- of one are context, as one hunk from the first to the last of them. `removed` maps a line to the text of
-- a removed line right before it. `hunkLabel` is git's function name for the hunk.
local function fileOf(lines: { string }, added: { number }, removed: { [number]: string }?, hunkLabel: string?): Pr.File
	local isAdded: { [number]: boolean } = {}
	local first: number = #lines
	local last: number = 1
	for _, n in added do
		isAdded[n] = true
		first = math.min(first, n - 3)
		last = math.max(last, n + 3)
	end
	first = math.max(first, 1)
	last = math.min(last, #lines)
	local rows: { Pr.Row } = { { kind = "hunk", oldStart = first, newStart = first, label = hunkLabel } :: Pr.Hunk }
	for n = first, last do
		if removed and removed[n] then table.insert(rows, { kind = "del", text = removed[n], old = n } :: Pr.Line) end
		if isAdded[n] then
			table.insert(rows, { kind = "add", text = lines[n], new = n } :: Pr.Line)
		else
			table.insert(rows, { kind = "ctx", text = lines[n], old = n, new = n } :: Pr.Line)
		end
	end
	return { path = "a.ts", status = "modified", adds = #added, dels = 0, rows = rows, src = lines }
end

-- The layout of a block showing the step over new-side lines from..to.
local function blockOf(fd: Diff.FileDiff, from: number, to: number): Diff.Layout
	local span = Diff.stepSpan(fd, { side = "new", from = from, to = to })
	assert(span, "no span for " .. from .. "-" .. to)
	return Diff.layout(fd, { spans = { span :: Diff.Interval }, whole = false, annotated = {}, hit = nil, reveals = {} })
end

-- Shown runs of entries as "first-last", in order; a gap prints as "gap" or "gap:label".
local function shape(layout: Diff.Layout): string
	local parts = {}
	for _, segment in layout.segments do
		if segment.kind == "rows" then
			table.insert(parts, segment.first .. "-" .. segment.last)
		elseif segment.kind == "gap" then
			table.insert(parts, if segment.label then "gap:" .. segment.label else "gap")
		else
			table.insert(parts, "native")
		end
	end
	return table.concat(parts, " ")
end

-- `count` body lines at `indent`, numbered from 1 within the body.
local function body(indent: string, count: number): { string }
	local out = {}
	for i = 1, count do table.insert(out, indent .. "step" .. i .. "()") end
	return out
end

-- A one-line file at `path` whose line is added.
local function fileAt(path: string, line: string): Pr.File
	local rows: { Pr.Row } = { { kind = "hunk", oldStart = 1, newStart = 1 } :: Pr.Hunk, { kind = "add", text = line, new = 1 } :: Pr.Line }
	return { path = path, status = "added", adds = 1, dels = 0, rows = rows, src = { line } }
end

-- The tokens of `line` in a file at `path` as "kind:text", skipping whitespace.
local function colored(path: string, line: string): string
	local fd = Diff.analyze(fileAt(path, line))
	assert(fd.syntax, "no syntax for " .. path)
	local parts = {}
	for _, token in Diff.tokens(fd, 1) do
		if string.match(token.text, "%S") then table.insert(parts, token.kind .. ":" .. token.text) end
	end
	return table.concat(parts, " ")
end

local function concat(...: { string }): { string }
	local out = {}
	for _, list in { ... } do
		for _, line in list do table.insert(out, line) end
	end
	return out
end

return function()
	-- A change in the middle of a function shows from the function's first line, and the lines
	-- before it stay hidden.
	local lines = concat({ "local x = 1", "", "function foo()" }, body("\t", 7), { "\tchange()", "\tafter()", "end", "local y = 2" })
	local fd = Diff.analyze(fileOf(lines, { 11 }))
	local layout = blockOf(fd, 11, 11)
	assert(shape(layout) == "gap 3-13 gap", shape(layout)) -- entries 1-2 hidden, function line is entry 3
	assert(layout.rows == 11, tostring(layout.rows))
	-- The pulled-in lines are plain context: only the changed line is marked.
	for i = 3, 10 do assert(not fd.entries[i].changed and fd.entries[i].row.kind == "ctx") end
	assert(fd.entries[11].row.kind == "add")

	-- A block of two steps in one function doesn't repeat the lines between them.
	lines = concat({ "function foo()" }, body("\t", 6), { "\tone()" }, body("\t", 9), { "\ttwo()", "end" })
	fd = Diff.analyze(fileOf(lines, { 8, 18 }))
	local one = Diff.stepSpan(fd, { side = "new", from = 8, to = 8 }) :: Diff.Interval
	local two = Diff.stepSpan(fd, { side = "new", from = 18, to = 18 }) :: Diff.Interval
	layout = Diff.layout(fd, { spans = { one, two }, whole = false, annotated = {}, hit = nil, reveals = {} })
	assert(shape(layout) == "1-19", shape(layout))
	assert(layout.rows == 19)

	-- The opener is at most SCOPE_REACH (30) entries above the step; farther, the block keeps its two
	-- lines of context and the gap above says where it is.
	lines = concat({ "x = 1", "function foo()" }, body("\t", 29), { "\tchange()", "end", "y = 2" })
	fd = Diff.analyze(fileOf(lines, { 32 }, nil, "function bar()"))
	assert(shape(blockOf(fd, 32, 32)) == "gap 2-34", "opener 30 entries above")
	lines = concat({ "x = 1", "function foo()" }, body("\t", 30), { "\tchange()", "end", "y = 2" })
	fd = Diff.analyze(fileOf(lines, { 33 }, nil, "function bar()"))
	layout = blockOf(fd, 33, 33)
	assert(shape(layout) == "gap:function foo() 31-35", shape(layout) .. " opener 31 entries above")
	assert(layout.rows == 5)

	-- The label is the opener's text, trimmed of indentation and cut when long.
	lines = concat({ "class A {", "\tfunction foo(" .. string.rep("a, ", 40) .. ") {" }, body("\t\t", 40), { "\t\tchange()", "\t}", "}" })
	fd = Diff.analyze(fileOf(lines, { 43 }))
	layout = blockOf(fd, 43, 43)
	local label = (layout.segments[1] :: Diff.Gap).label :: string
	assert(string.sub(label, 1, 14) == "function foo(a" and string.sub(label, -3) == "…" and #label <= 83, label)

	-- No line encloses a top-level change, so its block is today's: two lines each side and no label.
	lines = concat({ "function foo()" }, body("\t", 12), { "end", "top = 1", "more = 2" })
	fd = Diff.analyze(fileOf(lines, { 15 }, nil, "function foo()"))
	layout = blockOf(fd, 15, 15)
	assert(shape(layout) == "gap 13-16", shape(layout))

	-- A step that starts with a declaration begins at it; it isn't dragged up to the class. Neither is
	-- one that starts with a method, but a control block is.
	lines = concat({ "class A {" }, body("\t", 12), { "\tmethod() {", "\t\tbody()", "\t}", "}" })
	fd = Diff.analyze(fileOf(lines, { 14, 15 }))
	assert(shape(blockOf(fd, 14, 15)) == "gap 12-17", shape(blockOf(fd, 14, 15)))
	lines[14] = "\tpublic async method(a: string): void {"
	fd = Diff.analyze(fileOf(lines, { 14, 15 }))
	assert(shape(blockOf(fd, 14, 15)) == "gap 12-17")
	lines[14] = "\tfunction method() {"
	fd = Diff.analyze(fileOf(lines, { 14, 15 }))
	assert(shape(blockOf(fd, 14, 15)) == "gap 12-17")
	lines[14] = "\tif (method) {"
	fd = Diff.analyze(fileOf(lines, { 14, 15 }))
	assert(shape(blockOf(fd, 14, 15)) == "1-17", shape(blockOf(fd, 14, 15)))

	-- Blank lines are skipped when walking up, and a blank first line of the step doesn't set its indentation.
	lines = { "function foo()", "\tvalue = 1", "", "", "\tlocal a = 1", "", "\tchange()", "end", "", "x = 1" }
	fd = Diff.analyze(fileOf(lines, { 6, 7 }))
	layout = blockOf(fd, 6, 7)
	assert(shape(layout) == "1-9 gap", shape(layout))

	-- A change inside nested blocks starts at the function, not at the `if` right above it.
	lines = concat({ "function foo()", "\tif a then" }, body("\t\t", 4), { "\t\tif b then", "\t\t\tchange()", "\t\tend", "\tend", "end" })
	fd = Diff.analyze(fileOf(lines, { 8 }))
	layout = blockOf(fd, 8, 8)
	assert(shape(layout) == "1-10 gap", shape(layout))
	-- Out of reach, the function's line is the label: the block itself is today's.
	lines = concat({ "function foo()" }, body("\t", 40), { "\tif a then", "\t\tchange()", "\tend", "end" })
	fd = Diff.analyze(fileOf(lines, { 43 }))
	layout = blockOf(fd, 43, 43)
	assert(shape(layout) == "gap:function foo() 41-45", shape(layout))
	-- An inner function is the nearest declaration.
	lines = concat({ "class A {", "\touter() {", "\t\tstep()", "\t\tstep()", "\t\tcb(() => {" }, body("\t\t\t", 4), { "\t\t\tchange()", "\t\t})", "\t}", "}" })
	fd = Diff.analyze(fileOf(lines, { 10 }))
	assert(shape(blockOf(fd, 10, 10)) == "gap 5-12 gap", shape(blockOf(fd, 10, 10)))

	-- `} else {` and a wrapped signature are never the opener; the walk reaches what encloses them.
	lines = { "function foo(", "\ta,", "\tb", ") {", "\tif (a) {", "\t\tone()", "\t} else {", "\t\tchange()", "\t}", "}" }
	fd = Diff.analyze(fileOf(lines, { 8 }))
	assert(shape(blockOf(fd, 8, 8)) == "1-10", shape(blockOf(fd, 8, 8)))

	-- A less indented line that opens nothing narrows the walk: a statement continued over lines.
	lines = { "local a = 1", "function foo()", "\tlocal x =", "\t\t1 +", "\t\tchange", "end" }
	fd = Diff.analyze(fileOf(lines, { 5 }))
	assert(shape(blockOf(fd, 5, 5)) == "gap 2-6", shape(blockOf(fd, 5, 5)))
	-- ...and with nothing that declares above it, a non-declaring opener is where the walk ends.
	lines = { "local a = 1", "do", "\tlocal x =", "\t\t1 +", "\t\tchange", "end" }
	fd = Diff.analyze(fileOf(lines, { 5 }))
	assert(shape(blockOf(fd, 5, 5)) == "gap 2-6", shape(blockOf(fd, 5, 5)))

	-- A step of only a closing line is enclosed by the line that opened it; one of only blank lines
	-- has no scope.
	lines = { "x = 1", "function foo()" }
	for _ = 1, 10 do table.insert(lines, "\tstep()") end
	table.insert(lines, "end")
	table.insert(lines, "y = 2")
	fd = Diff.analyze(fileOf(lines, { 13 }))
	layout = blockOf(fd, 13, 13)
	assert(shape(layout) == "gap 2-14", shape(layout))
	lines = { "x = 1", "function foo()", "\tstep()", "", "\tstep()", "end" }
	fd = Diff.analyze(fileOf(lines, { 4 }))
	assert(shape(blockOf(fd, 4, 4)) == "gap 2-6", shape(blockOf(fd, 4, 4)))

	-- Python: a def is found by its keyword; a trailing comment doesn't hide a brace opener.
	lines = { "import os", "", "class A:", "    def run(self):  # runs", "        step()", "        change()", "        step()" }
	fd = Diff.analyze(fileOf(lines, { 6 }))
	assert(shape(blockOf(fd, 6, 6)) == "gap 4-7", shape(blockOf(fd, 6, 6)))
	lines = concat({ "class A {", "\tfoo(a) { // note" }, body("\t\t", 4), { "\t\tchange()", "\t}", "}" })
	fd = Diff.analyze(fileOf(lines, { 7 }))
	assert(shape(blockOf(fd, 7, 7)) == "gap 2-9", shape(blockOf(fd, 7, 7)))
	-- Tabs and spaces count one column each; with nothing declaring, the outermost opener is the scope.
	lines = { "x = {", "\tkey = {", "\t\tchange = 1,", "\t},", "}" }
	fd = Diff.analyze(fileOf(lines, { 3 }))
	assert(shape(blockOf(fd, 3, 3)) == "1-5", shape(blockOf(fd, 3, 3)))

	-- Allman braces: the line before a lone `{` comes with it.
	lines = { "int x;", "void run()", "{", "\ta();", "\tb();", "\tc();", "\tchange();", "}" }
	fd = Diff.analyze(fileOf(lines, { 7 }))
	assert(shape(blockOf(fd, 7, 7)) == "gap 2-8", shape(blockOf(fd, 7, 7)))

	-- Removed lines: a step over them walks up from them, old side or new.
	lines = { "x = 1", "function foo()", "\ta()", "\tb()", "\tnew()", "end" }
	fd = Diff.analyze(fileOf(lines, { 5 }, { [5] = "\told()" }))
	layout = blockOf(fd, 5, 5)
	assert(shape(layout) == "gap 2-7" and fd.entries[5].row.kind == "del" and fd.entries[6].row.kind == "add", shape(layout))
	local oldSpan = Diff.stepSpan(fd, { side = "old", from = 5, to = 5 }) :: Diff.Interval
	layout = Diff.layout(fd, { spans = { oldSpan }, whole = false, annotated = {}, hit = nil, reveals = {} })
	assert(shape(layout) == "gap 2-7", shape(layout))
	-- A removed line is never what opens the scope above: the file has the new side's lines only.
	lines = { "setup", "\ta()", "\tb()", "\tc()", "\tchange()", "\td()" }
	fd = Diff.analyze(fileOf(lines, { 5 }, { [3] = "function ghost() {" }))
	assert(fd.entries[3].row.kind == "del")
	assert(shape(blockOf(fd, 5, 5)) == "gap 4-7", shape(blockOf(fd, 5, 5)))

	-- A deleted file has no source: its removed lines are the text, so they can open a scope.
	local deleted: Pr.File = {
		path = "gone.ts", status = "removed", adds = 0, dels = 5, src = nil,
		rows = {
			{ kind = "hunk", oldStart = 1, newStart = 0 } :: Pr.Row,
			{ kind = "del", text = "function foo()", old = 1 },
			{ kind = "del", text = "\ta()", old = 2 },
			{ kind = "del", text = "\tb()", old = 3 },
			{ kind = "del", text = "\tc()", old = 4 },
			{ kind = "del", text = "end", old = 5 },
		},
	}
	fd = Diff.analyze(deleted)
	local gone = Diff.stepSpan(fd, { side = "old", from = 4, to = 4 }) :: Diff.Interval
	layout = Diff.layout(fd, { spans = { gone }, whole = false, annotated = {}, hit = nil, reveals = {} })
	local first = layout.segments[1] :: Diff.Rows
	assert(first.kind == "rows" and first.first == 1 and first.last == 5, shape(layout))

	-- Without the file source the walk stops at the edge of the hunk instead of crossing to an earlier one.
	local noSrc: Pr.File = {
		path = "b.ts", status = "modified", adds = 1, dels = 0, src = nil,
		rows = {
			{ kind = "hunk", oldStart = 1, newStart = 1 } :: Pr.Row,
			{ kind = "ctx", text = "function foo()", old = 1, new = 1 },
			{ kind = "ctx", text = "\ta()", old = 2, new = 2 },
			{ kind = "hunk", oldStart = 40, newStart = 40 } :: Pr.Row,
			{ kind = "ctx", text = "\tb()", old = 40, new = 40 },
			{ kind = "add", text = "\tchange()", new = 41 },
		},
	}
	fd = Diff.analyze(noSrc)
	assert(shape(blockOf(fd, 41, 41)) == "gap 2-4", shape(blockOf(fd, 41, 41)))

	-- A block that isn't made of steps, or shows the whole file, is not extended.
	lines = concat({ "function foo()" }, body("\t", 20), { "\tchange()", "end" })
	fd = Diff.analyze(fileOf(lines, { 22 }))
	layout = Diff.layout(fd, { spans = nil, whole = false, annotated = {}, hit = nil, reveals = {} })
	assert(shape(layout) == "gap 19-23", shape(layout))
	layout = Diff.layout(fd, { spans = nil, whole = true, annotated = {}, hit = nil, reveals = {} })
	assert(shape(layout) == "1-23", shape(layout))

	-- A line's run starts at the first line of its segment, at a step break, and after a line with a
	-- comment card; a gap starts a new run, and a hidden line is in none.
	lines = concat(body("", 40))
	fd = Diff.analyze(fileOf(lines, { 5, 30 }))
	local hidden = { kind = "gap" } :: any -- the runs don't read a gap's fields
	local segments: { Diff.Segment } = {
		{ kind = "rows", first = 1, last = 6 } :: Diff.Rows, hidden,
		{ kind = "rows", first = 10, last = 20 } :: Diff.Rows, hidden,
		{ kind = "rows", first = 25, last = 32 } :: Diff.Rows,
	}
	-- A file with its source has an entry per line, so the card under line 12 sits under entry 12.
	local starts = Diff.runStarts(fd, segments, { [15] = true }, { [12] = true })
	local want = { [1] = 1, [6] = 1, [10] = 10, [12] = 10, [13] = 13, [14] = 13, [15] = 15, [20] = 15, [25] = 25, [32] = 25 }
	for entry, first in want do assert(starts[entry] == first, "entry " .. entry .. " starts in " .. tostring(starts[entry]) .. ", not " .. first) end
	assert(starts[7] == nil and starts[21] == nil, "hidden entries are in no run")
	assert(Diff.runStarts(fd, segments, {}, {})[14] == 10, "no break or card keeps one run")

	-- Each language colors its own keywords, comments and strings; an unknown extension stays plain.
	assert(colored("a.js", "const s = 'x' // y") == "kw:const plain:s punct:= str:'x' com:// y", colored("a.js", "const s = 'x' // y"))
	assert(colored("a.tsx", "return <A/>") == "kw:return punct:< type:A punct:/ punct:>", colored("a.tsx", "return <A/>"))
	assert(colored("a.py", "def f(): # note") == "kw:def fn:f punct:( punct:) punct:: com:# note", colored("a.py", "def f(): # note"))
	assert(colored("a.go", "func f() { /* a */ }") == "kw:func fn:f punct:( punct:) punct:{ com:/* a */ punct:}", colored("a.go", "func f() { /* a */ }"))
	assert(colored("a.rs", "fn f<'a>(x: &'a str)") == "kw:fn plain:f punct:< punct:' plain:a punct:> punct:( plain:x punct:: punct:& punct:' plain:a plain:str punct:)", colored("a.rs", "fn f<'a>(x: &'a str)"))
	assert(colored("q.sql", "SELECT id -- all") == "kw:SELECT plain:id com:-- all", colored("q.sql", "SELECT id -- all"))
	assert(colored("a.luau", "local x = 1 -- n") == "kw:local plain:x punct:= num:1 com:-- n", colored("a.luau", "local x = 1 -- n"))
	assert(Diff.analyze(fileAt("a.luau", "x")).language == "lua")
	local unknown = Diff.analyze(fileAt("a.zig", "const x = 1;"))
	assert(unknown.syntax == nil and unknown.language == "zig")
	-- A line outside a diff, such as one side of a conflict, colors by its path alone.
	local tokens = Diff.highlight("a.tsx", "const x = 1") :: { Diff.Token }
	assert(tokens[1].kind == "kw" and tokens[#tokens].kind == "num")
	assert(Diff.highlight("a.zig", "const x = 1") == nil)
end
