--!strict
-- The review page's two AI passes: whichever lands first, the explanation turns the page guided and
-- the review's comments end up on it, a failed pass leaves the other's work in place, and a summary
-- the reader edited survives. Fetch's passes are replaced by ones the test settles by hand.
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

type World = { b: any, cx: any, toasts: { string }, settleExplain: (ok: boolean) -> (), settleReview: (ok: boolean) -> (), disk: { [string]: any } }

local function world(review: boolean): World
	local p = pr()
	local toasts: { string } = {}
	local disk: { [string]: any } = {}
	local explainDone, reviewDone = nil :: any, nil :: any
	AgentHost.explain = function(_agent, _repo, _pr, done) explainDone = done end
	AgentHost.draftReview = function(_agent, _repo, _pr, done) reviewDone = done end
	Fetch.expectedSeconds = function() return 60 end
	Fetch.saveSeconds = function() end
	local cx: any = {}
	function cx:render() end
	function cx:toast(_level: string, text: string) table.insert(toasts, text) end
	local agent = Agent.new("/omp", "/bin", Agent.picks({ model = "a/opus-5", review = review }, nil) :: Agent.Picks)
	local b: any = {
		opts = { pr = "7", repo = "/r", post = false }, dir = "/r", name = "#7",
		repo = { root = "/r", guides = "/r/.git/prguide" }, guided = false, ai = Agent.idle(agent),
	}
	-- Opening the PR: no guide or review file yet.
	Host.fs.exists = function(path: string): boolean return disk[path] ~= nil end
	local Notice = require("../src/view/notice")
	b.notice = Notice.loading("#7", "")
	local guide = Guide.defaultGuide(p)
	local State = require("../src/state")
	b.page = State.new(p, guide, { dryRunPath = "/tmp/x" })
	b.page.ai = b.ai
	Block.event(b, { ev = "action", act = "generate-guide" }, cx)
	return {
		b = b, cx = cx, toasts = toasts, disk = disk,
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
	local reading: { [string]: any } = {}
	Host.now = function(): number return 0 end
	Host.timer = function(): any return { cancel = function() end } end
	Host.fs = { exists = function(): boolean return false end, read = function(path: string): string return path end }
	Host.json = { decode = function(path: string): any return reading[path] end }
	local ok, err = pcall(function()
		-- Explanation first: the page turns guided at once, the review row stays, then comments land.
		local w = world(true)
		assert(w.b.ai.explaining and w.b.ai.reviewing, "both passes start together")
		w.settleExplain(true)
		assert(w.b.guided and w.b.page.review.guide.guided, "the explanation shows as soon as it lands")
		assert(w.b.page.ai == w.b.ai and w.b.ai.reviewing, "the page still shows the review going")
		assert(commentIds(w.b) == "", "no comments before the review lands")
		w.b.page.review.summary.text = "Mine."
		w.settleReview(true)
		assert(commentIds(w.b) == "r1", "the review's comments land on the guided page")
		assert(w.b.page.review.summary.text == "Mine.", "a summary the reader edited is kept")
		assert(w.b.page.ai == nil, "the AI row goes once both passes are done")
		assert(w.toasts[#w.toasts] == "1 review comment drafted", w.toasts[#w.toasts])

		-- Review first: it waits in its file until the explanation picks it up.
		w = world(true)
		reading[REVIEW_PATH] = REVIEW_RAW
		w.settleReview(true)
		assert(not w.b.guided and commentIds(w.b) == "", "the review waits for the explanation")
		w.settleExplain(true)
		assert(w.b.guided and commentIds(w.b) == "r1" and w.b.page.review.summary.text == "Drafted.", "the explanation lands with the review on it")

		-- The explanation fails after the review landed: the default walkthrough takes the comments.
		w = world(true)
		w.settleReview(true)
		w.settleExplain(false)
		assert(not w.b.guided and commentIds(w.b) == "r1", "the default walkthrough takes the review")
		assert(w.b.ai.error == "it timed out", "the explanation's failure shows")

		-- The explanation fails before the review lands: the review still reaches the page.
		w = world(true)
		w.settleExplain(false)
		assert(w.b.page.ai == w.b.ai and w.b.ai.reviewing)
		w.settleReview(true)
		assert(not w.b.guided and commentIds(w.b) == "r1")

		-- The review fails: the guide stays and a toast says why.
		w = world(true)
		w.settleExplain(true)
		w.settleReview(false)
		assert(w.b.guided and commentIds(w.b) == "" and w.b.page.ai == nil)
		assert(w.toasts[#w.toasts] == "Couldn't draft review comments: it crashed", w.toasts[#w.toasts])

		-- Review off: only the explanation runs, and a review file left by an earlier run stays out.
		reading[REVIEW_PATH] = REVIEW_RAW
		w = world(false)
		w.disk[REVIEW_PATH] = REVIEW_RAW
		assert(w.b.ai.explaining and not w.b.ai.reviewing, "no review pass when it is off")
		w.settleExplain(true)
		assert(w.b.guided and w.b.page.ai == nil, "nothing left running")
		assert(commentIds(w.b) == "", "an old review file isn't merged when the review is off")
	end)
	for name, value in savedHost do Host[name] = value end
	for name, fn in saved do AgentHost[name] = fn end
	for name, fn in savedFetch do Fetch[name] = fn end
	if not ok then error(err, 0) end
end
