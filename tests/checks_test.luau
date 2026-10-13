--!strict
-- The checks popover: GitHub's answer parsed into check rows, the groups and times the popover shows, its state on
-- the hub (open, move, press, close), and the keys that drive it.
local Cases: any = require("../fixtures/hub/cases")
local Checks = require("../src/hub/checks")
local Fake = require("./fake-runner")
local Github = require("../src/github")
local Keys = require("../src/keys")
local Raw: any = require("../fixtures/hub/raw-check-list")
local State = require("../src/hub/state")

-- 2026-10-09T12:00:00Z, the cases clock.
local NOW = 1791547200

local function row(name: string, state: Checks.CheckState, patch: { [string]: any }?): Checks.CheckRow
	local out: any = { name = name, source = "CI", state = state, startedAt = nil, completedAt = nil, url = "https://ci/" .. name }
	for key, value in (patch or {}) do out[key] = value end
	return out
end

-- The lines as one string: "#Label n" for a header, "name|sub" for a check, "Show n" for the fold.
local function show(lines: { Checks.Line }): string
	local out: { string } = {}
	for _, line in lines do
		if line.kind == "header" then
			table.insert(out, "#" .. line.label .. " " .. line.count .. (if line.skipped > 0 then " +" .. line.skipped else ""))
		elseif line.kind == "check" then
			table.insert(out, line.row.name .. "|" .. line.sub)
		else
			table.insert(out, "Show " .. line.count .. (if line.fresh then " more" else ""))
		end
	end
	return table.concat(out, "\n")
end

local function key(name: string, shift: boolean?): any
	return { name = name, shift = shift or false, meta = false, ctrl = false, alt = false }
end

local function parsing()
	-- The recorded smoke-repo answer: a failed Actions check and a passing one, each with its workflow.
	local recorded = Github.parseCheckList(Raw) :: Checks.CheckList
	assert(recorded.headOid == "130d6a32040540d7d2ef41264d5d2a9fb5a6a314" and #recorded.rows == 2)
	local fail, ci = recorded.rows[1], recorded.rows[2]
	assert(fail.name == "fail" and fail.state == "failing" and fail.source == "smoke-fail" and string.find(fail.url, "/job/", 1, true))
	assert(ci.name == "ci" and ci.state == "passed" and ci.completedAt == "2026-10-11T00:50:44Z")

	-- Every state GitHub reports lands in one of the five; a status context has no source and runs from its time.
	local function run(status: string, conclusion: string?): any
		return { __typename = "CheckRun", name = status .. "/" .. tostring(conclusion), status = status, conclusion = conclusion, detailsUrl = "u", checkSuite = { app = { name = "Buildkite" } } }
	end
	local function context(state: string): any
		return { __typename = "StatusContext", context = "ctx/" .. state, state = state, targetUrl = "t", createdAt = "2026-10-09T11:00:00Z" }
	end
	local nodes = {
		run("COMPLETED", "SUCCESS"), run("COMPLETED", "NEUTRAL"), run("COMPLETED", "SKIPPED"), run("COMPLETED", "FAILURE"),
		run("COMPLETED", "TIMED_OUT"), run("COMPLETED", "CANCELLED"), run("COMPLETED", "ACTION_REQUIRED"), run("COMPLETED", "STARTUP_FAILURE"),
		run("IN_PROGRESS", nil), run("QUEUED", nil), run("PENDING", nil), run("WAITING", nil), run("REQUESTED", nil),
		context("SUCCESS"), context("FAILURE"), context("ERROR"), context("PENDING"), context("EXPECTED"), { __typename = "CheckRun" },
	}
	local doc = { data = { nodes = { { id = "PR_1", headRefOid = "abc", commits = { nodes = { { commit = { statusCheckRollup = { contexts = { nodes = nodes } } } } } } } } } }
	local list = Github.parseCheckList(doc) :: Checks.CheckList
	local states: { string } = {}
	for _, r in list.rows do table.insert(states, r.state) end
	assert(table.concat(states, " ") == "passed passed skipped failing failing failing failing failing running queued queued queued queued passed failing failing running queued", table.concat(states, " "))
	assert(list.rows[1].source == "Buildkite", "a check run with no workflow names its app")
	local pending = list.rows[17]
	assert(pending.name == "ctx/PENDING" and pending.source == nil and pending.startedAt == "2026-10-09T11:00:00Z" and pending.url == "t")
	assert(Github.parseCheckList({ data = { nodes = {} } }) == nil and Github.parseCheckList(nil) == nil)
	local none = Github.parseCheckList({ data = { nodes = { { id = "PR_1", headRefOid = "abc", commits = { nodes = { { commit = {} } } } } } } }) :: Checks.CheckList
	assert(none.headOid == "abc" and #none.rows == 0, "a commit with no checks is an empty list")

	-- One read: the PR node id in `nodes(ids:)`, and GitHub's failure in the "Couldn't load checks" words.
	local fake = Fake.new({ { prefix = { "gh", "api", "graphql" }, contains = "query CheckList", reply = { stdout = "RAW" } } })
	local got: Checks.CheckList? = nil
	Github.client(fake.run, function(): any return Raw end).checkList("PR_kwDOVC46H88AAAABHwf6iQ", function(value, err)
		assert(err == nil)
		got = value
	end)
	fake.expectOnly(1)
	assert(got and #got.rows == 2 and table.find(fake.calls[1].argv, "ids[]=PR_kwDOVC46H88AAAABHwf6iQ") ~= nil)
	local broken = Fake.new({ { prefix = { "gh", "api", "graphql" }, reply = { status = 1, stderr = "gh: Could not resolve to a node" } } })
	local reason: string? = nil
	Github.client(broken.run, function(): any return nil end).checkList("PR_x", function(_, err) reason = err and err.message end)
	assert(reason == "Couldn't load checks: Could not resolve to a node", tostring(reason))
end

local function shown()
	-- Times: elapsed for running, the wait for queued and skipped, what a finished check took.
	assert(Checks.clock(45) == "45s" and Checks.clock(384) == "6m 24s" and Checks.clock(3900) == "1h 05m" and Checks.clock(-3) == "0s")
	local running = row("e2e", "running", { startedAt = "2026-10-09T11:53:36Z" })
	assert(Checks.timeText(running, NOW) == "6m 24s" and Checks.sub(running, NOW) == "CI · 6m 24s")
	assert(Checks.timeText(row("q", "queued"), NOW) == "Queued" and Checks.timeText(row("s", "skipped"), NOW) == "Skipped")
	local passed = row("lint", "passed", { startedAt = "2026-10-09T11:00:00Z", completedAt = "2026-10-09T11:01:31Z", source = "" })
	assert(Checks.sub(passed, NOW) == "took 1m 31s", Checks.sub(passed, NOW))
	assert(Checks.timeText(row("ctx", "failing"), NOW) == "Failed" and Checks.timeText(row("ctx", "running"), NOW) == "Running")

	-- Groups in order Failing, Running, Queued, Passed (with the skipped count); Passed folds behind "Show N".
	local list: Checks.CheckList = { headOid = "h", rows = {
		passed, row("b-pass", "passed"), row("ios", "skipped"), running, row("deploy", "queued"), row("typecheck", "failing"),
	} }
	local pop: Checks.Popover = { key = "k", hl = 1, passedOpen = false, seen = {}, from = "board" }
	assert(show(Checks.lines(list, pop, NOW)) == table.concat({
		"#Failing 1", "typecheck|CI · Failed", "#Running 1", "e2e|CI · 6m 24s", "#Queued 1", "deploy|CI · Queued", "#Passed 2 +1", "Show 3",
	}, "\n"), show(Checks.lines(list, pop, NOW)))
	assert(#Checks.choices(Checks.lines(list, pop, NOW)) == 4, "headers are never highlighted")
	pop.passedOpen = true
	assert(string.find(show(Checks.lines(list, pop, NOW)), "#Passed 2 +1\nb-pass|CI · Passed\nlint|took 1m 31s\nios|CI · Skipped", 1, true))

	-- A check seen running that then passes stays at the top of Passed, above the fold.
	pop.passedOpen = false
	Checks.observe(pop, list)
	assert(pop.seen.e2e and pop.seen.deploy and not pop.seen.lint)
	local later: Checks.CheckList = { headOid = "h", rows = { passed, row("e2e", "passed"), row("deploy", "running") } }
	assert(show(Checks.lines(later, pop, NOW)) == "#Running 1\ndeploy|CI · Running\n#Passed 2\ne2e|CI · Passed\nShow 1 more", show(Checks.lines(later, pop, NOW)))
	assert(#Checks.lines({ headOid = "h", rows = {} }, pop, NOW) == 0)

	-- The card's mark and the fixes page's re-run state.
	local mark = Checks.mark({ state = "failing", passing = 3, failing = 1, pending = 2 }) :: Checks.Mark
	assert(mark.failing == 1 and mark.pending == 2 and mark.passed == 3)
	assert(Checks.mark({ state = "none", passing = 0, failing = 0, pending = 0 }) == nil)
	assert(Checks.rerunning(list, "e2e") == running and Checks.rerunning(list, "typecheck") == nil and Checks.rerunning(nil, "e2e") == nil)
	assert(Checks.rerunText(running, NOW) == "Re-running 6m 24s" and Checks.rerunText(row("deploy", "queued"), NOW) == "Re-running")
end

local function popover()
	local s = State.new(Cases.prs, Cases.asOf, nil)
	local KEY = "acme/web#111"
	local pr = State.prOf(s, KEY) :: any
	assert(State.openChecks(s, KEY) and s.mode == "checks" and s.checks and s.checks.from == "board")
	assert(State.checksWanted(s, KEY) and State.checkLoad(s, KEY) == nil and State.checksPress(s) == nil)
	State.setCheckLoad(s, KEY, pr.headOid, { state = "failed", reason = "GitHub's rate limit is reached" })
	assert(State.checksWanted(s, KEY))
	local retry = State.checksPress(s)
	assert(retry and retry.kind == "retry", "⏎ on a failed load reads it again")
	local list: Checks.CheckList = { headOid = pr.headOid, rows = {
		row("build", "failing"), row("e2e", "running", { startedAt = "2026-10-09T11:59:00Z" }), row("lint", "passed"), row("unit", "passed"),
	} }
	State.setCheckLoad(s, KEY, pr.headOid, { state = "loaded", list = list })
	assert(not State.checksWanted(s, KEY) and (s.checks :: any).seen.e2e, "a loaded list notes what is unfinished")
	assert(State.checksFailing(s))
	local open = State.checksPress(s)
	assert(open and open.kind == "open" and open.url == "https://ci/build" and open.name == "build")
	State.checksMove(s, 5)
	assert((s.checks :: any).hl == 3, "the highlight stops at the last row")
	local expand = State.checksPress(s)
	assert(expand and expand.kind == "expand" and (s.checks :: any).passedOpen)
	State.checksMove(s, 5)
	assert((s.checks :: any).hl == 4)
	local picked = State.checksPick(s, 2)
	assert(picked and picked.kind == "open" and picked.name == "e2e")
	State.closeChecks(s)
	assert(s.mode == "board" and s.checks == nil)

	-- Opened from the fixes page, closing returns to it; leaving the page closes the popover too.
	assert(State.openFixes(s, KEY) and State.openChecks(s, KEY))
	assert((s.checks :: any).from == "fixes")
	State.closeChecks(s)
	assert(s.mode == "fixes" and s.route ~= nil)
	State.openChecks(s, KEY)
	State.closeFixes(s)
	assert(s.mode == "board" and s.checks == nil)
	-- A new head commit is a new list.
	pr.headOid = "moved"
	assert(State.checkLoad(s, KEY) == nil)
	assert(not State.openChecks(s, "acme/web#999"))
end

local function keys()
	local s = State.new(Cases.prs, Cases.asOf, nil)
	State.select(s, "acme/web#111")
	local v = Keys.hubAction(s, key("v"))
	assert(v and v.act == "hub-checks" and v.value == "acme/web#111", "V opens the selected card's checks")
	s.search.text = "web"
	assert(Keys.hubAction(s, key("v")) == nil, "letters type while the search field has text")
	s.search.text = ""
	State.openFixes(s, "acme/web#111")
	local onPage = Keys.hubAction(s, key("v"))
	assert(onPage and onPage.act == "hub-checks" and onPage.value == "acme/web#111")

	State.openChecks(s, "acme/web#111")
	local function pressed(k: any): string
		local a = Keys.hubAction(s, k)
		return if a then a.act .. "=" .. (a.value or "") else "nil"
	end
	assert(pressed(key("j")) == "checks-move=1" and pressed(key("down")) == "checks-move=1")
	assert(pressed(key("k")) == "checks-move=-1" and pressed(key("up")) == "checks-move=-1")
	assert(pressed(key("enter")) == "checks-press=" and pressed(key("escape")) == "checks-close=" and pressed(key("v")) == "checks-close=")
	-- ⇧R re-runs only while a check fails: the board's count until the list says otherwise.
	assert(pressed(key("r", true)) == "card-rerun=acme/web#111")
	local pr = State.prOf(s, "acme/web#111") :: any
	State.setCheckLoad(s, pr.key, pr.headOid, { state = "loaded", list = { headOid = pr.headOid, rows = { row("build", "running") } } })
	assert(pressed(key("r", true)) == "nil", "nothing fails once the re-run is running")
	assert(pressed(key("x")) == "nil")
end

return function()
	parsing()
	shown()
	popover()
	keys()
end
