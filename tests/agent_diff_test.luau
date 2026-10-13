--!strict
-- What the explanation's diff leaves out: files it needn't read stay as one line under their header,
-- and hunks that only change whitespace are counted instead of shown, except where indentation is
-- meaning.
local Agent = require("../src/agent")
local Pr = require("../src/pr")

local function hunk(start: number): Pr.Row
	return { kind = "hunk", oldStart = start, newStart = start } :: Pr.Hunk
end

local function line(kind: "ctx" | "add" | "del", text: string, n: number): Pr.Row
	return { kind = kind, text = text, old = if kind == "add" then nil else n, new = if kind == "del" then nil else n } :: Pr.Line
end

local function file(path: string, rows: { Pr.Row }): Pr.File
	return { path = path, status = "modified", adds = 0, dels = 0, rows = rows }
end

-- `n` added lines under one hunk.
local function added(path: string, n: number): Pr.File
	local rows = { hunk(1) }
	for i = 1, n do table.insert(rows, line("add", "x = " .. i, i)) end
	return file(path, rows)
end

-- The lines of the diff for `f` alone, after the legend and its header.
local function body(f: Pr.File): string
	local diff = Agent.numberedDiff({ f })
	local after = string.match(diff, "=== [^\n]+\n(.*)$") :: string
	return (string.gsub(after, "\n+$", ""))
end

local function cuts()
	assert(Agent.cutReason(added("src/app.ts", 3)) == nil)
	local generated = added("gen/api.ts", 3)
	generated.group = "generated"
	assert(Agent.cutReason(generated) == "generated")
	assert(Agent.cutReason(added("vendor/lib/a.go", 1)) == "vendored")
	assert(Agent.cutReason(added("web/node_modules/x/index.js", 1)) == "vendored")
	assert(Agent.cutReason(added("third_party/zlib/zlib.h", 1)) == "vendored")
	assert(Agent.cutReason(added("src/vendors.ts", 1)) == nil, "a name that only starts like a vendored folder")
	assert(Agent.cutReason(added("public/app.min.js", 1)) == "minified")
	assert(Agent.cutReason(added("public/app.min.css", 1)) == "minified")
	assert(Agent.cutReason(added("src/__snapshots__/view.test.ts.snap", 1)) == "snapshot")
	assert(Agent.cutReason(added("ui/button.snap", 1)) == "snapshot")
	local long = file("public/bundle.js", { hunk(1), line("add", string.rep("a", 2001), 1) })
	assert(Agent.cutReason(long) == "minified", "a line no one writes by hand")
	assert(Agent.cutReason(file("src/a.js", { hunk(1), line("add", string.rep("a", 2000), 1) })) == nil)

	assert(body(added("vendor/big.go", 1204)) == "(vendored, 1,204 lines not shown)", body(added("vendor/big.go", 1204)))
	assert(body(added("ui/one.snap", 1)) == "(snapshot, 1 line not shown)")
	local binary = file("img/logo.png", {})
	binary.binary = true
	assert(body(binary) == "(binary, no lines)")
end

local function whitespace()
	local reindented = file("src/a.ts", {
		hunk(10), line("del", "  if (x) {", 10), line("add", "    if (x) {", 10), line("ctx", "}", 11),
		hunk(40), line("del", "return a", 40), line("add", "return b", 40),
		hunk(60), line("add", "", 60),
	})
	local shown = body(reindented)
	assert(string.sub(shown, 1, 37) == "(3 whitespace-only lines not shown)\n\n", shown)
	assert(string.find(shown, "@@ -40 +40 @@", 1, true) and string.find(shown, "return b", 1, true))
	assert(not string.find(shown, "if (x)", 1, true) and not string.find(shown, "@@ -60", 1, true), "both whitespace hunks are gone")

	-- Indentation is meaning in Python and YAML: every hunk is shown.
	for _, path in { "app/main.py", "ci/build.yml", "deploy/values.YAML" } do
		local indented = body(file(path, { hunk(10), line("del", "  run: x", 10), line("add", "    run: x", 10) }))
		assert(string.find(indented, "    run: x", 1, true) and not string.find(indented, "whitespace-only", 1, true), path)
	end
end

return function()
	cuts()
	whitespace()
end
