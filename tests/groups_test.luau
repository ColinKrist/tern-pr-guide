--!strict
-- Tests and generated files: the path classifier, git's output marking them, the order and sections
-- the page lists files in, what a guide and the agent's diff leave out, and how the supporting
-- area folds and opens them.
local Agent = require("../src/agent")
local FileGroup = require("../src/file-group")
local FileTree = require("../src/file-tree")
local GitOutput = require("../src/git-output")
local Guide = require("../src/guide")
local Pr = require("../src/pr")
local Review = require("../src/review")
local State = require("../src/state")

local function paths(files: { Pr.File }): string
	local out = {}
	for _, file in files do table.insert(out, file.path) end
	return table.concat(out, ",")
end

local function file(path: string, group: FileGroup.Group?, added: number?): Pr.File
	local count = added or 3
	local rows: { Pr.Row } = { { kind = "hunk", oldStart = 1, newStart = 1 } :: Pr.Hunk }
	for i = 1, count do table.insert(rows, { kind = "add", text = "line " .. i, new = i } :: Pr.Line) end
	return { path = path, status = "modified", adds = count, dels = 0, rows = rows, group = group }
end

local function pr(files: { Pr.File }): Pr.PR
	return { repo = "acme/api", number = 1, title = "t", body = "", url = "", author = "a", baseRef = "main", head = "abc", files = files }
end

-- A guide with one change whose steps visit `visited`.
local function guideOf(p: Pr.PR, visited: { string }): Guide.Guide
	local steps = {}
	for _, path in visited do table.insert(steps, { file = path, from = 1, to = 2, title = path, note = "" }) end
	local guide = Guide.parse({ schema = 1, changes = { { title = "Change", why = "", steps = steps } } }, p)
	assert(guide)
	return guide
end

local function isTests()
	for _, path in {
		"tests/a.ts", "test/a.ts", "src/__tests__/a.ts", "spec/models/user.rb", "specs/a.rb", "e2e/login.ts",
		"app/Tests/FooTests.swift", "src/Test/Foo.java", "web/E2E/a.ts", "src/test/java/FooTest.java",
		"a/foo_test.go", "a/foo.test.ts", "a/foo.spec.tsx", "pkg/test_util.py", "pkg/test_x.py",
		"app/FooTest.kt", "app/FooTests.swift", "spec_helper_spec.rb", "lib/user_spec.rb", "a.test.js",
	} do
		assert(FileGroup.isTest(path), path .. " is a test")
	end
	for _, path in {
		"src/latest.ts", "src/contest/a.ts", "src/testing/util.ts", "src/attest.py", "src/protest_x.py",
		"src/spec.ts", "src/test.ts", "src/testimony.ts", "src/Test.java", "src/Tests.swift", "src/tests_helper.go",
		"src/a.testx.ts", "src/FooTest.ts", "src/FooTests.java", "src/foo_spec.py", "src/unit/helper.ts", "docs/inspect/a.md",
		".test.ts", "src/footest.java", "src/test_.py", "specification/a.md", "src/testsuite/a.ts",
	} do
		assert(not FileGroup.isTest(path), path .. " is not a test")
	end
	-- Generated wins over tests; neither is no group.
	assert(FileGroup.of("tests/a.ts", true) == "generated")
	assert(FileGroup.of("tests/a.ts", false) == "tests")
	assert(FileGroup.of("src/a.ts", false) == nil)
end

local function gitOutput()
	local changes = GitOutput.changes("M\0src/a.ts\0M\0tests/a.test.ts\0M\0gen/api.ts\0D\0gen/old.ts\0M\0img/b.png\0")
	local generated = GitOutput.generated("gen/api.ts\0linguist-generated\0true\0src/a.ts\0linguist-generated\0unspecified\0gen/old.ts\0linguist-generated\0set\0")
	for _, change in changes do
		if generated[change.path] then change.generated = true end
	end
	local patches: { [string]: GitOutput.Patch } = {
		["src/a.ts"] = { rows = {}, adds = 1, dels = 0, binary = false },
		["gen/api.ts"] = { rows = {}, adds = 4000, dels = 1, binary = false },
		["img/b.png"] = { rows = {}, adds = 0, dels = 0, binary = true },
	}
	-- A generated file's source is never read, nor a deleted or binary file's.
	assert(table.concat(GitOutput.textPaths(changes, patches), ",") == "src/a.ts,tests/a.test.ts")
	local files = GitOutput.files(changes, patches, { ["src/a.ts"] = "x\n", ["gen/api.ts"] = "big\n" })
	assert(#files == 5)
	local byPath: { [string]: Pr.File } = {}
	for _, f in files do byPath[f.path] = f end
	assert(byPath["src/a.ts"].group == nil and byPath["src/a.ts"].src ~= nil)
	assert(byPath["tests/a.test.ts"].group == "tests")
	-- A generated file keeps its rows and counts, marked, and a deleted one is generated too.
	assert(byPath["gen/api.ts"].group == "generated" and byPath["gen/api.ts"].adds == 4000)
	assert(byPath["gen/old.ts"].group == "generated" and byPath["gen/old.ts"].src == nil)
	assert(byPath["img/b.png"].group == nil and byPath["img/b.png"].binary == true)
	-- Lockfiles stay out, generated or not.
	assert(GitOutput.isLockfile("web/package-lock.json") and GitOutput.isLockfile("go.sum") and not GitOutput.isLockfile("src/lock.ts"))
end

local function sections()
	local files = {
		file("gen/z.ts", "generated"), file("tests/b.test.ts", "tests"), file("src/b.ts", nil), file("gen/a.ts", "generated"),
		file("tests/a.test.ts", "tests"), file("README.md", nil), file("src/a.ts", nil),
	}
	local cut = FileTree.sections(files)
	assert(#cut == 3 and cut[1].group == nil and cut[2].group == "tests" and cut[3].group == "generated")
	assert(paths(cut[1].files) == "src/b.ts,README.md,src/a.ts")
	assert(paths(cut[2].files) == "tests/b.test.ts,tests/a.test.ts")
	assert(paths(cut[3].files) == "gen/z.ts,gen/a.ts")
	-- Each section is a tree of its own: folders before files, by name.
	assert(cut[1].rows[1].kind == "folder" and (cut[1].rows[1] :: any).path == "src" and (cut[1].rows[1] :: any).depth == 0)
	assert(paths(FileTree.order(files)) == "src/a.ts,src/b.ts,README.md,tests/a.test.ts,tests/b.test.ts,gen/a.ts,gen/z.ts")
	-- No test or generated file: one section, as before; nothing at all: none.
	assert(#FileTree.sections({ file("a.ts", nil) }) == 1 and #FileTree.sections({}) == 0)
	-- The unguided page takes its steps in the same order.
	local plain = Guide.defaultGuide(pr(files))
	local order = {}
	for _, step in plain.changes[1].steps do table.insert(order, step.file) end
	assert(table.concat(order, ",") == "src/a.ts,src/b.ts,README.md,tests/a.test.ts,tests/b.test.ts,gen/a.ts,gen/z.ts")
end

local function guideAndReview()
	local files = {
		file("src/a.ts", nil), file("src/b.ts", nil), file("tests/a.test.ts", "tests"), file("tests/b.test.ts", "tests"),
		file("gen/api.ts", "generated"), file("tests/gen.test.ts", "generated"),
	}
	local p = pr(files)
	-- A step on a test file stays in its change; one on a generated file is dropped.
	local guide = guideOf(p, { "src/a.ts", "tests/a.test.ts", "gen/api.ts" })
	assert(guide.guided and #guide.changes == 1 and #guide.changes[1].steps == 2)
	assert(guide.changes[1].steps[2].file == "tests/a.test.ts")
	-- A guide pointing only at generated files isn't a guide.
	local onlyGenerated = Guide.parse({ schema = 1, changes = { { title = "c", why = "", steps = { { file = "gen/api.ts", from = 1, to = 2, title = "t", note = "" } } } } }, p)
	assert(onlyGenerated and onlyGenerated.guided == false)
	-- Comments can't be on one either.
	local raw = { schema = 1, changes = { { title = "c", why = "", steps = { { file = "src/a.ts", from = 1, to = 2, title = "t", note = "" } } } },
		comments = { { id = "x", file = "gen/api.ts", line = 1, kind = "nit", body = "b" }, { id = "y", file = "tests/a.test.ts", line = 1, kind = "nit", body = "b" } } }
	local commented = Guide.parse(raw, p)
	assert(commented and #commented.comments == 1 and commented.comments[1].id == "y")

	local r = Review.new(p, guide)
	-- The visited test file isn't supporting, and isn't grouped away from its change.
	assert(paths(Review.supportingFiles(r)) == "src/b.ts,tests/b.test.ts,gen/api.ts,tests/gen.test.ts")
	local cut = Review.supportingSections(r)
	assert(#cut == 3)
	assert(cut[1].group == nil and paths(cut[1].files) == "src/b.ts")
	assert(cut[2].group == "tests" and paths(cut[2].files) == "tests/b.test.ts")
	assert(cut[3].group == "generated" and paths(cut[3].files) == "gen/api.ts,tests/gen.test.ts")

	-- Reviewed counts cover every file, generated ones with their own tick.
	assert(Review.counts(r).filesReviewed == 0)
	r.filesViewed["gen/api.ts"] = true
	assert(Review.isFileReviewed(r, "gen/api.ts") and not Review.isFileReviewed(r, "tests/b.test.ts"))
	assert(Review.counts(r).filesReviewed == 1)

	-- The agent reads no generated file, and does read tests.
	local diff = Agent.numberedDiff(files)
	assert(not string.find(diff, "gen/api.ts", 1, true) and not string.find(diff, "tests/gen.test.ts", 1, true))
	assert(string.find(diff, "=== tests/a.test.ts", 1, true) and string.find(diff, "=== src/a.ts", 1, true))
end

local function area()
	local files = { file("src/a.ts", nil), file("src/b.ts", nil), file("tests/a.test.ts", "tests", 50), file("gen/api.ts", "generated", 5000), file("gen/small.ts", "generated", 5) }
	local p = pr(files)
	local s = State.new(p, guideOf(p, { "src/a.ts" }), {})
	local tests, gen, big, plainFile = State.supportingBlock("tests/a.test.ts"), State.supportingBlock("gen/api.ts"), "gen/api.ts", State.supportingBlock("src/b.ts")
	-- A guided page starts with the groups folded.
	assert(s.foldedFolders["/tests"] and s.foldedFolders["/generated"])
	assert(State.inFoldedFolder(s, "tests/a.test.ts") and State.inFoldedFolder(s, "gen/api.ts") and not State.inFoldedFolder(s, "src/b.ts"))
	-- Open all opens the plain and test files, unfolding Tests, and leaves generated ones alone.
	State.toggleAllSupporting(s)
	assert(s.supportingOpen and s.fileOpen["src/b.ts"] and s.fileOpen["tests/a.test.ts"])
	assert(not s.fileOpen[big] and not s.fileOpen["gen/small.ts"] and not s.foldedFolders["/tests"] and s.foldedFolders["/generated"])
	local plan = State.plan(s)
	assert(plan.open[plainFile] and plan.open[tests] and not plan.open[gen])
	-- Open again closes them all, and a generated file the reader opened by hand with them.
	State.openSupportingFile(s, "gen/small.ts")
	assert(s.fileOpen["gen/small.ts"] and not s.foldedFolders["/generated"], "opening a generated file unfolds its group")
	State.toggleAllSupporting(s)
	assert(not s.fileOpen["src/b.ts"] and not s.fileOpen["tests/a.test.ts"] and not s.fileOpen["gen/small.ts"])
	-- With Tests folded again, open all unfolds it instead of closing.
	s.foldedFolders["/tests"] = true
	State.toggleAllSupporting(s)
	assert(s.fileOpen["tests/a.test.ts"] and not s.foldedFolders["/tests"])
	State.toggleAllSupporting(s)
	assert(not s.fileOpen["tests/a.test.ts"])
	-- A huge generated file the reader opened is theirs to open: the budget never folds it.
	State.openSupportingFile(s, big)
	assert(State.plan(s).open[gen])

	-- The file view lists the groups unfolded: it steps through every file.
	local unguided = State.new(p, Guide.defaultGuide(p), {})
	assert(next(unguided.foldedFolders) == nil)
	assert(paths(FileTree.order(p.files)) == "src/a.ts,src/b.ts,tests/a.test.ts,gen/api.ts,gen/small.ts")
end

return function()
	isTests()
	gitOutput()
	sections()
	guideAndReview()
	area()
end
