--!strict
-- U on a failing check's panel: the details' base comparison read from GitHub, the strip's choice between Update
-- branch and Push empty commit, the key, and on the real hub block the question Push empty commit asks before its
-- three GitHub calls.
local Block: any = require("../src/hub/block")
local Cases: any = require("../fixtures/hub/cases")
local Details = require("../src/hub/details")
local Fixes = require("../src/hub/fixes")
local FixesView = require("../src/view/hub/fixes")
local Github = require("../src/github")
local Host: any = require("../src/host")
local Keys = require("../src/keys")
local State = require("../src/hub/state")

local KEY = "acme/web#111"

local function key(name: string, mods: { [string]: boolean }?): any
	local m = mods or {}
	return { name = name, shift = m.shift == true, meta = m.meta == true, ctrl = false, alt = false }
end

local function same(a: { string }, b: { string }, what: string)
	assert(table.concat(a, " ") == table.concat(b, " "), what .. ": " .. table.concat(a, " "))
end

local function parsing()
	local pr = State.prOf(State.new(Cases.prs, Cases.asOf, nil), KEY) :: any
	local function parse(node: { [string]: any }): Fixes.FixDetails
		node.id, node.headRefOid = pr.id, pr.headOid
		return Github.parseDetails({ data = { node = node } }, pr) :: Fixes.FixDetails
	end
	local behind = parse({ headRefName = "fix/retry", headRepository = { nameWithOwner = "fork/web" }, baseRef = { compare = { behindBy = 20 } } })
	assert(behind.behindBy == 20 and behind.branch and behind.branch.repo == "fork/web" and behind.branch.name == "fix/retry")
	assert(parse({ baseRef = { compare = { behindBy = 0 } } }).behindBy == 0)
	-- GitHub's null (dropped by the decoder) is unknown, not up to date; a deleted fork has no branch to push to.
	local unknown = parse({ headRefName = "fix/retry", baseRef = { compare = {} } })
	assert(unknown.behindBy == nil and unknown.branch == nil)
	assert(parse({}).behindBy == nil)
end

local function commands()
	same(Github.commands.headTree("fork/web", "abc123").argv, { "gh", "api", "repos/fork/web/git/commits/abc123", "--jq", ".tree.sha" }, "tree")
	same(Github.commands.emptyCommit("fork/web", "tree9", "abc123").argv, {
		"gh", "api", "repos/fork/web/git/commits", "-X", "POST", "-f", "message=Empty commit to re-run checks",
		"-f", "tree=tree9", "-f", "parents[]=abc123", "--jq", ".sha",
	}, "commit")
	same(Github.commands.moveBranch("fork/web", "fix/retry", "new456").argv,
		{ "gh", "api", "repos/fork/web/git/refs/heads/fix/retry", "-X", "PATCH", "-f", "sha=new456", "-F", "force=false" }, "ref")
end

-- Every text in the panel's action strip, in order.
local function strip(s: State.State): { string }
	local root: any = FixesView.view(s, { born = {}, next = {}, booted = true, animate = false })
	local found: any = nil
	local function walk(node: any)
		if found or type(node) ~= "table" then return end
		if node.p and node.p.key == "strip" then found = node return end
		for _, child in node.c or {} do walk(child) end
	end
	walk(root)
	assert(found, "the check panel draws its strip")
	local out: { string } = {}
	local function texts(node: any)
		if node.p and node.p.text then table.insert(out, node.p.text) end
		for _, child in node.c or {} do texts(child) end
	end
	texts(found)
	return out
end

local function has(list: { string }, text: string): boolean
	return table.find(list, text) ~= nil
end

local function strips()
	local function page(behindBy: number?, conflicts: boolean?): State.State
		local prs = {}
		for _, pr in Cases.prs do table.insert(prs, if pr.key == KEY then table.clone(pr) else pr) end
		local s = State.new(prs, Cases.asOf, nil)
		local pr = State.prOf(s, KEY) :: any
		pr.conflicts = conflicts == true
		assert(State.openFixes(s, KEY))
		State.setDetails(s, {
			key = KEY, headOid = pr.headOid, fetchedAt = "", reviews = {}, threads = {}, changedPaths = {},
			checks = { { name = "build", workflow = nil, runId = nil, url = "https://buildkite.com/acme/web/builds/1", summary = nil, annotations = {} } },
			conflicts = nil, conflictNote = nil, files = nil, behindBy = behindBy, branch = { repo = "acme/web", name = "fix/retry" },
		})
		return s
	end

	local s = page(3)
	local shown = strip(s)
	assert(has(shown, "Update branch") and has(shown, "3 commits behind main") and not has(shown, "Push empty commit"), table.concat(shown, "|"))
	local u = Keys.hubAction(s, key("u"))
	assert(u and u.act == "fixes-update", "U sends the button's action")
	assert(table.find(State.fixItems(s, State.fixStep(s)), "update"), "j/k reach the button")
	s.search.text = "x"
	assert(Keys.hubAction(s, key("u")) == nil, "letters type while the search field has text")

	assert(has(strip(page(1)), "1 commit behind main"))

	s = page(0)
	shown = strip(s)
	assert(has(shown, "Push empty commit") and has(shown, "Up to date with main") and not has(shown, "Update branch"), table.concat(shown, "|"))
	assert((Keys.hubAction(s, key("u")) :: any).act == "fixes-update")
	State.fixAsk(s, true)
	shown = strip(s)
	assert(has(shown, "Push an empty commit to fix/retry?") and has(shown, "Confirm") and not has(shown, "Push empty commit"), table.concat(shown, "|"))
	assert((Keys.hubAction(s, key("enter", { meta = true })) :: any).act == "fixes-empty-confirm")
	assert((Keys.hubAction(s, key("escape")) :: any).act == "fixes-empty-cancel", "Esc answers the question, not the page")
	assert(Keys.hubAction(s, key("j")) == nil)

	-- Conflicts, or a count GitHub didn't give: neither button, and U does nothing.
	for _, s2 in { page(3, true), page(0, true), page(nil) } do
		shown = strip(s2)
		assert(not has(shown, "Update branch") and not has(shown, "Push empty commit"), table.concat(shown, "|"))
		assert(Keys.hubAction(s2, key("u")) == nil)
		assert(table.find(State.fixItems(s2, State.fixStep(s2)), "update") == nil)
	end
end

-- The real block on the sample board: #111 is 3 commits behind, #104 up to date. GitHub is swapped for a recorder.
local function block()
	local stub: { [string]: any } = {
		timer = function(): any return { cancel = function() end } end,
		json = { decode = function(): any return nil end, encode = function(): string return "" end },
		getenv = function(): string? return nil end,
		kv = { get = function(): any return nil end, set = function() end },
	}
	local hostFields: { [string]: any } = {}
	for name, value in stub do
		hostFields[name] = Host[name]
		Host[name] = value
	end
	local ok, err = pcall(function()
		local toasts: { string } = {}
		local cx: any = { cwd = "/reader" }
		function cx:render() end
		function cx:frame() end
		function cx:toast(_kind: string, title: string) table.insert(toasts, title) end
		local ran: { string } = {}
		local function open(target: string, replies: { [string]: string }?): any
			local b: any = Block.init(cx, { "fixture=cases" }, nil)
			Details.openFixes(b, cx, target)
			b.fixture = nil
			b.github = {
				run = function(command: any, done: (string?, any) -> ())
					local line = table.concat(command.argv, " ")
					table.insert(ran, line)
					for prefix, out in replies or {} do
						if string.find(line, prefix, 1, true) then return done(out, nil) end
					end
					done(nil, { operation = "gh api", message = "gh: Update is not a fast forward (HTTP 422)" })
				end,
			}
			table.clear(toasts)
			table.clear(ran)
			return b
		end
		local function act(b: any, name: string)
			Block.event(b, { ev = "action", act = name, value = "" } :: any, cx)
		end

		local b = open(KEY, { ["update-branch"] = "" })
		act(b, "fixes-update")
		same(ran, { "gh pr update-branch 111 --repo acme/web" }, "Update branch runs at once")
		assert(toasts[1] == "Updated #111 with main", toasts[1])
		assert(State.branchAction(b.s, KEY) == nil, "the button goes once the branch is caught up")

		-- The sample's #104 is Tandem's: the question still asks, and the answer sends nothing to its branch.
		local up = "acme/web#104"
		b = open(up, { ["/git/commits/"] = "tree9" })
		act(b, "fixes-update")
		act(b, "fixes-empty-confirm")
		assert(#ran == 0 and toasts[1] == "Couldn't push an empty commit: Tandem watches this pull request", toasts[1])

		local function mine(target: string, replies: { [string]: string }?): any
			local opened = open(target, replies)
			opened.watched = {}
			for _, pr in opened.s.prs do pr.tandem = false end
			return opened
		end
		b = mine(up, { ["/git/commits/"] = "tree9\n", ["git/commits -X POST"] = "new456\n", ["git/refs/heads/"] = "{}" })
		act(b, "fixes-update")
		assert(#ran == 0 and b.s.route.ask, "Push empty commit asks before anything is sent")
		act(b, "fixes-empty-cancel")
		assert(#ran == 0 and not b.s.route.ask)
		act(b, "fixes-update")
		act(b, "fixes-empty-confirm")
		assert(#ran == 3 and string.find(ran[2], "tree=tree9", 1, true) and string.find(ran[3], "sha=new456", 1, true), table.concat(ran, "\n"))
		assert(toasts[1] == "Pushed an empty commit to #104", toasts[1])
		assert(b.s.busy[up] == nil and not b.s.route.ask)

		-- A branch that moved meanwhile refuses the fast-forward.
		b = mine(up, { ["/git/commits/"] = "tree9", ["git/commits -X POST"] = "new456" })
		act(b, "fixes-update")
		act(b, "fixes-empty-confirm")
		assert(#ran == 3 and toasts[1] == "Couldn't push an empty commit: the branch moved; refresh and try again", toasts[1])
		assert(b.s.busy[up] == nil)

		-- The sample board sends nothing.
		b = mine(up)
		b.fixture = "cases"
		act(b, "fixes-update")
		act(b, "fixes-empty-confirm")
		assert(#ran == 0 and toasts[1] == "The sample board doesn't push commits", toasts[1])
	end)
	for name in stub do Host[name] = hostFields[name] end
	if not ok then error(err, 0) end
end

return function()
	parsing()
	commands()
	strips()
	block()
end
