--!strict
-- Reading what a pull request's pages show: its feedback details (`readFeedback`, which a bot fix and Summarize share),
-- the fixes page's details and local git (`openFixes`), the review fix page's files (`openReviewFix`), and the sample
-- board's recorded details in place of each.
local AgentHost = require("../agent-host")
local Fetch = require("../fetch")
local Fixes = require("./fixes")
local Host = require("../host")
local Model = require("./model")
local Prdata = require("../prdata")
local ReviewFix = require("./review-fix")
local Runtime = require("./runtime")
local State = require("./state")
local Summary = require("./summary")

type Block = Runtime.Block

local FIXTURES, draw, reasonOf, isoNow = Runtime.FIXTURES, Runtime.draw, Runtime.reasonOf, Runtime.isoNow

local sampleDetails: (pr: Model.HubPR) -> Fixes.FixDetails

-- Feedback consumers share #12's details, without opening a checkout or reading annotated code. GitHub's
-- feedback changes without a new head, so a live board reads it again for every explicit action. A read
-- is rejected when the board's feedback for the PR changed while it was out. The result is the feedback
-- that is still live on the PR (`Summary.current`).
local function readFeedback(b: Block, pr: Model.HubPR, done: (Fixes.FixDetails?, string?) -> ())
	local known = b.s.details[pr.key]
	if b.fixture then
		local d = if known and known.headOid == pr.headOid then known else sampleDetails(pr)
		State.setDetails(b.s, d)
		return done(Summary.current(d, pr), nil)
	end
	local signature = State.feedbackSignature(pr)
	local called = false
	local function received(d: Fixes.FixDetails?, err: Model.Error?)
		if called then return end
		called = true
		if b.closed then return end
		local latest = State.prOf(b.s, pr.key)
		if not latest or latest.headOid ~= pr.headOid or State.feedbackSignature(latest) ~= signature
			or not d or d.headOid ~= pr.headOid then
			return done(nil, if err then err.message else "Feedback changed or is unavailable; refresh the board")
		end
		-- The same commit keeps what git said last time, as the fixes page does.
		if known and known.headOid == d.headOid then d.conflicts, d.conflictNote, d.files = known.conflicts, known.conflictNote, known.files end
		State.setDetails(b.s, d)
		done(Summary.current(d, latest), nil)
	end
	local ok, err = pcall(b.github.details, pr, received)
	if not ok then received(nil, { operation = "details", message = tostring(err) }) end
end

-- Review fix: only P can push, only confirmed D can discard, and neither forgets a held lease.
local function openReviewFix(b: Block, cx: BlockCx, key: string)
	if not State.openReviewFix(b.s, key) then return end
	local agent = b.s.agents[key]
	if not agent or agent.kind ~= "ready" then return end
	if agent.review then return end
	local route, fix = b.s.route :: State.Route, agent.fix
	local function read(value: AgentHost.AgentFixRead?, err: string?)
		if b.s.agents[key] ~= agent then return end
		if value then agent.review = ReviewFix.build(fix, value.files, b.s.details[key], value.originals) end
		if b.s.route == route then
			route.loading = false
			route.error = if value then nil else "Couldn't read the fix: " .. reasonOf(err or "no answer")
		end
		if not b.closed then draw(b, cx) end
	end
	if b.fixture then
		local data: any = FIXTURES["review-fix"]()
		local bot = fix.hunks[1] and string.sub(fix.hunks[1].id, 1, 4) == "bot:"
		local files = if not bot and data.fix.commit == fix.commit then data.files else nil
		-- Other lifecycle samples have captured resolutions but no commit files. Assemble a
		-- recorded preview without running git; the dedicated sample carries actual file text.
		if not files then
			files = {}
			for _, hunk in fix.hunks do
				local lines = table.clone(hunk.context.before)
				for _, line in (if hunk.resolved then hunk.resolved.lines else {}) do table.insert(lines, line.text) end
				for _, line in hunk.context.after do table.insert(lines, line) end
				files[hunk.path] = (files[hunk.path] or "") .. table.concat(lines, "\n") .. "\n"
			end
		end
		read({ files = files, diff = "" }, nil)
		return
	end
	local ok, err = pcall(AgentHost.readAgentFix, fix, read)
	if not ok then read(nil, tostring(err)) end
end

-- The fixes page ---------------------------------------------------------------------------------------------
-- ⏎ on a Needs fixes card. The details are read once when it opens (one GraphQL call); the conflicted files and
-- the annotated source come from local git when the repo has a checkout. Reply and Resolve are GraphQL writes.

-- The annotated source files of the details' failing checks, each once.
local function annotatedPaths(d: Fixes.FixDetails): { string }
	local paths: { string } = {}
	for _, check in d.checks do
		for _, annotation in Fixes.usable(check.annotations) do
			if table.find(paths, annotation.path) == nil then table.insert(paths, annotation.path) end
		end
	end
	return paths
end

-- Reads the conflicts and the annotated files from the repo's checkout (or PR Guide's saved copy). With none, the
-- conflict step says so, and its files are unknown.
local function readGit(b: Block, cx: BlockCx, pr: Model.HubPR, d: Fixes.FixDetails)
	local paths = annotatedPaths(d)
	if not pr.conflicts and #paths == 0 then return end
	local dir = cx.cwd or Host.getenv("HOME") or ""
	Fetch.checkoutFor(nil, dir, pr.repo, function(found)
		if b.closed then return end
		local repo = found or Fetch.readySavedCopy(pr.repo)
		if repo == nil then
			if pr.conflicts then d.conflictNote = "No local copy of " .. pr.repo end
			return draw(b, cx)
		end
		Prdata.readFixes(repo, pr, paths, function(read, err)
			if b.closed then return end
			if read == nil then
				if pr.conflicts then d.conflictNote = "Couldn't read the conflicts: " .. reasonOf(err or "no answer") end
				return draw(b, cx)
			end
			d.files = read.files
			if pr.conflicts then
				local tree = Fixes.parseMergeTree(read.mergeTree or "")
				if tree then
					d.conflicts, d.conflictNote = Fixes.conflicts(tree, read.shown, read.logs), nil
				else
					d.conflictNote = "Couldn't read the conflicts: git printed nothing usable"
				end
			end
			draw(b, cx)
		end)
	end)
end

-- The sample board's details: the fixture for the card's key, with the recorded git output for its conflicts.
sampleDetails = function(pr: Model.HubPR): Fixes.FixDetails
	local summaries: any = require("../../fixtures/hub/summary")
	for _, details in summaries.details do
		if details.key == pr.key then return table.clone(details) end
	end
	-- Comments-only boards of fixture=cases: the thread the board records, so Summarize stays the action.
	local commented = summaries.cases[pr.key]
	if commented then
		local d = table.clone(commented)
		d.headOid = pr.headOid
		return d
	end
	if Model.botFeedback(pr) then
		local fixture = summaries
		local d = table.clone(fixture.details.bot)
		d.key, d.headOid = pr.key, pr.headOid
		return d
	end
	local fixture: any = require("../../fixtures/hub/fixes")
	local kind = fixture.sample[pr.key]
	local source: Fixes.FixDetails = if kind then fixture.details[kind] else fixture.details.failure
	local d = table.clone(source)
	d.key, d.headOid, d.fetchedAt, d.conflicts, d.conflictNote = pr.key, pr.headOid, "", nil, nil
	if pr.conflicts then
		local read = fixture.gitRead.conflictMany
		d.conflicts = Fixes.conflicts(Fixes.parseMergeTree(read.mergeTree) :: Fixes.MergeTree, read.shown, read.logs)
	end
	return d
end

local function openFixes(b: Block, cx: BlockCx, key: string)
	local s = b.s
	if not State.openFixes(s, key) then return end
	local pr = State.prOf(s, key) :: Model.HubPR
	if b.fixture then
		State.setDetails(s, sampleDetails(pr))
		return
	end
	local route = s.route :: State.Route
	local known = s.details[key]
	b.github.details(pr, function(d, err)
		if b.closed then return end
		if d == nil then
			if s.route == route then route.loading, route.error = false, if err then err.message else "no answer" end
			return draw(b, cx)
		end
		d.fetchedAt = isoNow()
		-- The same commit keeps what git said last time while it is read again.
		if known and known.headOid == d.headOid then d.conflicts, d.conflictNote, d.files = known.conflicts, known.conflictNote, known.files end
		State.setDetails(s, d)
		draw(b, cx)
		readGit(b, cx, pr, d)
	end)
end

return {
	readFeedback = readFeedback,
	openFixes = openFixes,
	openReviewFix = openReviewFix,
}
