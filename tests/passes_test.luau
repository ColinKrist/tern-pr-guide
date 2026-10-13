--!strict
-- The review page's two AI passes, each started on its own: Generate guide explains and turns the
-- page guided, Draft review comments puts comments on whichever page is shown, with or without a
-- guide, and either order of landing ends with both on the page. A failed pass leaves the other's
-- work in place, and a summary the reader edited survives. AgentHost's passes are replaced by ones
-- the test settles by hand.
local Agent = require("../src/agent")
local Block: any = require("../src/block")
local AgentHost: any = require("../src/agent-host")
local Fetch: any = require("../src/fetch")
local Host: any = require("../src/host")
local Guide: any = require("../src/guide")
local Pr = require("../src/pr")

local REVIEW_PATH = "/r/.git/prguide/7.review.json"

local function pr(): Pr.PR
	local rows: { Pr.Row } = { { kind = "hunk", oldStart = 1, newStart = 1 } :: Pr.Hunk }
	for i = 1, 4 do table.insert(rows, { kind = "add", text = "line " .. i, new = i } :: Pr.Line) end
	local file: Pr.File = { path = "src/a.ts", status = "modified", adds = 4, dels = 0, rows = rows }
	return { repo = "acme/api", number = 7, title = "t", body = "", url = "", author = "a", createdAt = "", baseRef = "main", head = "abc", files = { file } }
end

local REVIEW_RAW = { schema = 1, author = "opus-5", lens = "Balanced", summary = "Drafted.", comments = { { id = "r1", file = "src/a.ts", line = 3, kind = "question", body = "Why?" } } }

type World = {
	b: any, cx: any, toasts: { string }, disk: { [string]: any }, calls: { explain: number, review: number },
	generate: () -> (), draft: () -> (), settleExplain: (ok: boolean) -> (), settleReview: (ok: boolean) -> (),
}

local function world(): World
	local p = pr()
	local toasts: { string } = {}
	local disk: { [string]: any } = {}
	local calls = { explain = 0, review = 0 }
	local explainDone, reviewDone = nil :: any, nil :: any
	AgentHost.explain = function(_agent, _repo, _pr, done)
		calls.explain += 1
		explainDone = done
	end
	AgentHost.draftReview = function(_agent, _repo, _pr, done)
		calls.review += 1
		-- Starting the review clears its file, as runPass does.
		disk[REVIEW_PATH] = nil
		reviewDone = done
	end
	Fetch.expectedSeconds = function() return 60 end
	Fetch.saveSeconds = function() end
	local cx: any = {}
	function cx:render() end
	function cx:toast(_level: string, text: string) table.insert(toasts, text) end
	local agent = Agent.new("/omp", "/bin", Agent.picks({ model = "a/opus-5" }, {}) :: Agent.Picks)
	local b: any = {
		opts = { pr = "7", repo = "/r", post = false }, dir = "/r", name = "#7",
		repo = { root = "/r", guides = "/r/.git/prguide" }, guided = false, ai = Agent.idle(agent),
	}
	-- Opening the PR: no guide or review file yet.
	Host.fs.exists = function(path: string): boolean return disk[path] ~= nil end
	Host.json.decode = function(path: string): any return disk[path] end
	local Notice = require("../src/view/notice")
	b.notice = Notice.loading("#7", "")
	local State = require("../src/state")
	b.page = State.new(p, Guide.defaultGuide(p), { dryRunPath = "/tmp/x" })
	b.page.ai = b.ai
	return {
		b = b, cx = cx, toasts = toasts, disk = disk, calls = calls,
		generate = function() Block.event(b, { ev = "action", act = "generate-guide" }, cx) end,
		-- The key, so ⇧R and the button's click are one action.
		draft = function() Block.key(b, { name = "r", shift = true, meta = false, ctrl = false, alt = false }, cx) end,
		settleExplain = function(ok: boolean)
			local parsed = Guide.parse({ schema = 1, overview = "Over.", changes = { { title = "Do it", steps = { { file = "src/a.ts", from = 1, to = 2, title = "Step", note = "" } } } } }, p)
			if ok then explainDone(parsed, nil) else explainDone(nil, "it timed out") end
		end,
		settleReview = function(ok: boolean)
			if ok then
				disk[REVIEW_PATH] = REVIEW_RAW
				reviewDone(Guide.parseDraft(REVIEW_RAW, p), nil)
			else
				reviewDone(nil, "it crashed")
			end
		end,
	}
end

local function commentIds(b: any): string
	local out = {}
	for _, c in b.page.review.guide.comments do table.insert(out, c.id) end
	return table.concat(out, ",")
end

return function()
	local saved = { explain = AgentHost.explain, draftReview = AgentHost.draftReview }
	local savedFetch = { expectedSeconds = Fetch.expectedSeconds, saveSeconds = Fetch.saveSeconds }
	local savedHost = { now = Host.now, timer = Host.timer, fs = Host.fs, json = Host.json }
	Host.now = function(): number return 0 end
	Host.timer = function(): any return { cancel = function() end } end
	Host.fs = { read = function(path: string): string return path end }
	Host.json = {}
	local ok, err = pcall(function()
		-- Generate guide explains only, and the guided page keeps the row that drafts comments.
		local w = world()
		w.generate()
		assert(w.b.ai.explaining and not w.b.ai.reviewing and w.calls.review == 0, "Generate guide runs only the explanation")
		w.settleExplain(true)
		assert(w.b.guided and w.b.page.review.guide.guided, "the explanation shows as soon as it lands")
		assert(w.toasts[#w.toasts] == "Guide ready", w.toasts[#w.toasts])
		assert(w.b.page.ai == w.b.ai, "a guided page still offers the agent")
		w.generate()
		assert(w.calls.explain == 1, "a page with a guide isn't explained again")

		-- Draft review comments on the guided page: the comments land on it, an edited summary stays.
		w.draft()
		assert(w.b.ai.reviewing and not w.b.ai.explaining, "the review starts on its own")
		w.draft()
		assert(w.calls.review == 1, "one review at a time")
		w.b.page.review.summary.text = "Mine."
		w.settleReview(true)
		assert(commentIds(w.b) == "r1", "the review's comments land on the guided page")
		assert(w.b.page.review.summary.text == "Mine.", "a summary the reader edited is kept")
		assert(w.toasts[#w.toasts] == "1 review comment drafted", w.toasts[#w.toasts])
		assert(not w.b.ai.reviewing, "nothing left running")

		-- Without a guide: the default walkthrough takes the comments.
		w = world()
		w.draft()
		w.settleReview(true)
		assert(not w.b.guided and commentIds(w.b) == "r1" and w.b.page.review.summary.text == "Drafted.", "comments land without a guide")

		-- Both running, the review first: its comments show at once, and the guide keeps them.
		w = world()
		w.draft()
		w.generate()
		assert(w.b.ai.explaining and w.b.ai.reviewing, "both run side by side when both are asked for")
		w.settleReview(true)
		assert(not w.b.guided and commentIds(w.b) == "r1", "the review lands before the guide")
		w.settleExplain(true)
		assert(w.b.guided and commentIds(w.b) == "r1" and w.b.page.review.summary.text == "Drafted.", "the guide lands with the review on it")

		-- Both running, the explanation first: the review lands on the new guided page.
		w = world()
		w.generate()
		w.draft()
		w.settleExplain(true)
		assert(w.b.guided and commentIds(w.b) == "" and w.b.ai.reviewing, "the guide shows while the review runs")
		w.settleReview(true)
		assert(w.b.guided and commentIds(w.b) == "r1", "then the comments join it")

		-- The explanation fails after the review landed: the default walkthrough keeps the comments.
		w = world()
		w.draft()
		w.generate()
		w.settleReview(true)
		w.settleExplain(false)
		assert(not w.b.guided and commentIds(w.b) == "r1", "the default walkthrough keeps the review")
		assert(w.b.ai.error == "it timed out", "the explanation's failure shows")

		-- The review fails: the guide stays and a toast says why.
		w = world()
		w.generate()
		w.settleExplain(true)
		w.draft()
		w.settleReview(false)
		assert(w.b.guided and commentIds(w.b) == "" and not w.b.ai.reviewing)
		assert(w.toasts[#w.toasts] == "Couldn't draft review comments: it crashed", w.toasts[#w.toasts])

		-- Comments drafted before, kept in their file, join a guide generated now, as opening the PR would show them.
		w = world()
		w.disk[REVIEW_PATH] = REVIEW_RAW
		w.generate()
		w.settleExplain(true)
		assert(w.b.guided and commentIds(w.b) == "r1", "an earlier review joins the new guide")
	end)
	for name, value in savedHost do Host[name] = value end
	for name, fn in saved do AgentHost[name] = fn end
	for name, fn in savedFetch do Fetch[name] = fn end
	if not ok then error(err, 0) end
end
