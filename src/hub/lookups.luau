--!strict
-- What the board looks up beside a refresh: how each repo merges (its `hub.merge.<owner>/<repo>` record in kv, else
-- GitHub's answer, saved once) and, for a Needs fixes card with a failing check, whether the failure looks flaky.
local Fixes = require("./fixes")
local Github = require("../github")
local Host = require("../host")
local Model = require("./model")
local Runtime = require("./runtime")
local State = require("./state")
local Store = require("./store")
local Sync = require("./sync")

type Block = Runtime.Block

local draw, reasonOf, isoNow = Runtime.draw, Runtime.reasonOf, Runtime.isoNow
local kvGet = Store.kvGet

-- Merge methods: hub.merge.<owner>/<repo> -----------------------------------------------------------------

local KV_MERGE = "hub.merge."

-- The repo's saved record, read from kv once. A fixture board keeps its records in memory only.
local function readRecord(b: Block, repo: string): Sync.MergeRecord?
	local known = b.records[repo]
	if known or b.fixture then return known end
	local record = Sync.loadMerge(kvGet(KV_MERGE .. repo))
	b.records[repo] = record
	return record
end

-- Resolves the repo's method from its record (user, declared, learned, GitHub default) into the state.
local function resolveRepo(b: Block, repo: string)
	local record = readRecord(b, repo)
	if not record then return end
	local default: "squash" | "merge" | "rebase" = "squash"
	if record.viewerDefault == "merge" or record.viewerDefault == "rebase" then default = record.viewerDefault end
	State.setMerge(b.s, repo, Model.resolveMergeMethod(Sync.mergeEvidence(record, default)))
end

-- Saves the record (a fixture board keeps it in memory) and resolves the repo again. Returns why it failed.
local function saveRecord(b: Block, repo: string, record: Sync.MergeRecord): string?
	b.records[repo] = record
	local why: string? = nil
	if not b.fixture then
		local ok, err = pcall(Host.kv.set, KV_MERGE .. repo, record)
		if not ok then why = tostring(err) end
	end
	resolveRepo(b, repo)
	return why
end

local function recordOf(b: Block, repo: string): Sync.MergeRecord
	return readRecord(b, repo) or { schema = 1, learnedAnswered = false }
end

-- Resolves every repo with a saved record, so the cards know how their repo merges.
local function loadMerges(b: Block)
	local seen: { [string]: boolean } = {}
	for _, pr in b.s.prs do
		if pr.role == "mine" and not seen[pr.repo] then
			seen[pr.repo] = true
			resolveRepo(b, pr.repo)
		end
	end
end

-- Asks GitHub how a repo merges, once per repo: what it declares and the habit of its last 8 merges (1 point).
-- The same answer carries the repo's "Allow auto-merge" setting, which Merge when ready needs: with `needAuto`, a repo
-- whose record is saved is asked once per session for that alone.
local function detectRepo(b: Block, cx: BlockCx, repo: string, needAuto: boolean?)
	if b.fixture or b.closed or b.detecting[repo] then return end
	local known = readRecord(b, repo)
	if known and not (needAuto and b.s.autoMerge[repo] == nil) then return end
	b.detecting[repo] = true
	b.github.detect(repo, function(found, err)
		if b.closed then return end
		if found then
			State.setAutoMerge(b.s, repo, found.autoMergeAllowed)
			if not known then
				local record = recordOf(b, repo)
				record.declared, record.learned, record.viewerDefault, record.checkedAt = found.declared, found.learned, found.viewerDefault, isoNow()
				local why = saveRecord(b, repo, record)
				if why then cx:toast("error", "Couldn't save how " .. repo .. " merges: " .. why) end
			end
		else
			b.detecting[repo] = nil
			cx:toast("error", "Couldn't check how " .. repo .. " merges: " .. reasonOf(if err then err.message else "no answer"))
		end
		draw(b, cx)
	end)
end

-- After a refresh: every repo with a Ready card that has no record yet is checked.
local function detectMerges(b: Block, cx: BlockCx)
	if b.fixture then return end
	for _, entry in b.s.board.columns do
		if entry.column == "ready" then
			for _, card in entry.cards do detectRepo(b, cx, card.pr.repo) end
		elseif entry.column == "in_review" then
			for _, card in entry.cards do detectRepo(b, cx, card.pr.repo, true) end
		end
	end
end

-- Flake evidence ----------------------------------------------------------------------------------------------
-- For each Needs fixes card with a failing check, the block reads what the verdict needs: the details (annotations,
-- changed files, run ids), the base branch's recent runs (once an hour per repo) and the runs of the head commit.
-- Nothing here re-runs anything: that is a press on Re-run failed checks.
local FLAKE_PRS = 10 -- the most cards read in one pass

local function flakeOf(pr: Model.HubPR, d: Fixes.FixDetails, history: Github.RepoHistory?, runs: { Github.RunRow }?): State.Flake
	local verdicts: { Model.FlakeVerdict } = {}
	for _, check in d.checks do
		if check.runId then table.insert(verdicts, Model.flake(Github.evidenceFor(check, d.changedPaths, history, runs))) end
	end
	local verdict = Model.flakeAll(verdicts)
	return { flaky = verdict.flaky and #verdicts > 0, reason = verdict.reason, headOid = d.headOid }
end

local function loadFlakes(b: Block, cx: BlockCx)
	if b.fixture or b.closed or b.flights.flake then return end
	local queue: { Model.HubPR } = {}
	for _, entry in b.s.board.columns do
		if entry.column == "needs_fixes" then
			for _, card in entry.cards do
				local pr = card.pr
				local wants = table.find(card.reasons, "checks") ~= nil and pr.checks.failing > 0
				if wants and not b.flakeTried[pr.key .. "@" .. pr.headOid] and State.flakeOf(b.s, pr.key) == nil and #queue < FLAKE_PRS then
					table.insert(queue, pr)
				end
			end
		end
	end
	if #queue == 0 then return end
	b.flights.flake = true
	local function step(i: number)
		local pr = queue[i]
		if pr == nil or b.closed then
			b.flights.flake = false
			return
		end
		b.flakeTried[pr.key .. "@" .. pr.headOid] = true
		b.github.details(pr, function(d, _)
			if b.closed then return end
			if d == nil then return step(i + 1) end
			b.histories.read(pr.repo, pr.baseBranch, Host.time(), function(history)
				b.github.runs(pr.repo, d.headOid, function(runs, _)
					if b.closed then return end
					State.setFlake(b.s, pr.key, flakeOf(pr, d, history, runs))
					draw(b, cx)
					step(i + 1)
				end)
			end)
		end)
	end
	step(1)
end

-- A comment, label or queue method chosen or saved in the merge menu becomes the repo's setting.
local function setUserMethod(b: Block, cx: BlockCx, repo: string, method: Model.MergeMethod)
	local record = recordOf(b, repo)
	record.user = method
	local why = saveRecord(b, repo, record)
	if why then cx:toast("error", "Couldn't save how " .. repo .. " merges: " .. why) end
end

return {
	saveRecord = saveRecord,
	recordOf = recordOf,
	loadMerges = loadMerges,
	detectRepo = detectRepo,
	detectMerges = detectMerges,
	loadFlakes = loadFlakes,
	setUserMethod = setUserMethod,
}
