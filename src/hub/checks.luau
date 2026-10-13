--!strict
-- What the checks popover shows: a pull request's reviewers, its checks in groups (Failing, Running, Queued, then Passed
-- behind a fold), the time each one reads, the card's checks mark, the PR page's reviews mark, and the popover's own
-- state. Pure: no clock, no network,
-- no Tern; `now` (seconds) is passed in. github.luau parses GitHub's answer into these shapes.
local Model = require("./model")

export type CheckState = "failing" | "running" | "queued" | "passed" | "skipped"
-- One check on the head commit. `source` is its workflow, else the app that ran it; `url` is its details link.
export type CheckRow = { name: string, source: string?, state: CheckState, startedAt: string?, completedAt: string?, url: string }
export type CheckList = { headOid: string, rows: { CheckRow } }
-- A check list while and after it is read, as `Log.Load` is for a log.
export type Load = { state: "loading" } | { state: "loaded", list: CheckList } | { state: "failed", reason: string }

-- The open popover: the card it is for, the highlighted row (1-based, over the rows that can be chosen), whether
-- Passed is unfolded, the checks seen unfinished while it was open (by name), and where it opened: a card's checks
-- mark, the fixes page's All checks row, or a PR page's status marks.
export type Origin = "board" | "fixes" | "page"
export type Popover = { key: string, hl: number, passedOpen: boolean, seen: { [string]: boolean }, from: Origin }

-- A line of the popover: a group's header, a check with its second line, or the fold that hides the rest of Passed.
export type Line =
	{ kind: "header", label: string, count: number, skipped: number }
	| { kind: "check", row: CheckRow, sub: string }
	| { kind: "more", count: number, fresh: boolean } -- `fresh`: rows that finished while open sit above it ("Show 9 more")

-- The card's checks mark: failing in red, unfinished in amber with the spinner, all done in green.
export type Mark = { failing: number, pending: number, passed: number }

-- A PR page's reviews mark: approved (with how many approved), changes requested, or a review still wanted.
export type ReviewMark = { kind: "approved", approvals: number } | { kind: "changes" } | { kind: "required" }

-- A row of the popover's Reviewers: who, where they stand, and "Approved · 2h" (just "Requested" while they owe one).
export type ReviewerState = "approved" | "changes" | "commented" | "requested"
export type Reviewer = { name: string, state: ReviewerState, sub: string }

export type Counts = { failing: number, running: number, queued: number, passed: number, skipped: number }

local M = {}

local GROUPS: { { state: CheckState, label: string } } = {
	{ state = "failing", label = "Failing" },
	{ state = "running", label = "Running" },
	{ state = "queued", label = "Queued" },
}

-- "45s", "6m 24s", "1h 05m".
function M.clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s < 60 then return s .. "s" end
	if s < 3600 then return (s // 60) .. "m " .. string.format("%02d", s % 60) .. "s" end
	return (s // 3600) .. "h " .. string.format("%02d", (s % 3600) // 60) .. "m"
end

local function took(row: CheckRow): string?
	local from = if row.startedAt then Model.epoch(row.startedAt) else nil
	local to = if row.completedAt then Model.epoch(row.completedAt) else nil
	if from and to then return "took " .. M.clock(to - from) end
	return nil
end

-- How long a check ran or has been running, or where it waits.
function M.timeText(row: CheckRow, now: number): string
	if row.state == "running" then
		local from = if row.startedAt then Model.epoch(row.startedAt) else nil
		return if from then M.clock(now - from) else "Running"
	end
	if row.state == "queued" then return "Queued" end
	if row.state == "skipped" then return "Skipped" end
	return took(row) or (if row.state == "failing" then "Failed" else "Passed")
end

-- The row's second line: "CI · took 1m 31s".
function M.sub(row: CheckRow, now: number): string
	local time = M.timeText(row, now)
	return if row.source and row.source ~= "" then row.source .. " · " .. time else time
end

function M.counts(list: CheckList): Counts
	local c: Counts = { failing = 0, running = 0, queued = 0, passed = 0, skipped = 0 }
	for _, row in list.rows do
		if row.state == "failing" then c.failing += 1
		elseif row.state == "running" then c.running += 1
		elseif row.state == "queued" then c.queued += 1
		elseif row.state == "passed" then c.passed += 1
		else c.skipped += 1 end
	end
	return c
end

-- Whether any check has yet to finish.
function M.unfinished(list: CheckList): boolean
	local c = M.counts(list)
	return c.running + c.queued > 0
end

-- The card's mark from the board's counts.
function M.mark(checks: Model.Checks): Mark?
	if checks.state == "none" then return nil end
	return { failing = checks.failing, pending = checks.pending, passed = checks.passing }
end

-- The reviews mark from GitHub's decision; a repo that requires no review has none, so its reviewers' latest verdicts
-- stand in.
function M.reviewMark(reviews: Model.ReviewState): ReviewMark
	local approvals, changes = 0, false
	for _, review in reviews.latest do
		if review.verdict == "approved" then approvals += 1 end
		if review.verdict == "changes_requested" then changes = true end
	end
	local decision = reviews.decision
	if decision == "changes_requested" or (decision == "none" and changes) then return { kind = "changes" } end
	if decision == "approved" or (decision == "none" and approvals > 0) then return { kind = "approved", approvals = approvals } end
	return { kind = "required" }
end

local VERDICTS: { [Model.Verdict]: { state: ReviewerState, label: string } } = {
	approved = { state = "approved", label = "Approved" },
	changes_requested = { state = "changes", label = "Changes requested" },
	commented = { state = "commented", label = "Commented" },
}

-- Each reviewer's latest review, then the people and teams asked who haven't reviewed. A dismissed review is no stand.
function M.reviewers(reviews: Model.ReviewState, now: number): { Reviewer }
	local out: { Reviewer } = {}
	local seen: { [string]: boolean } = {}
	for _, review in reviews.latest do
		local verdict = VERDICTS[review.verdict]
		if verdict then
			seen[review.author] = true
			local ago = string.gsub(Model.ago(review.at, now), " ago$", "")
			table.insert(out, { name = review.author, state = verdict.state, sub = if ago == "" then verdict.label else verdict.label .. " · " .. ago })
		end
	end
	for _, name in reviews.requested do
		local reviewer: Reviewer = { name = name, state = "requested", sub = "Requested" }
		if not seen[name] then table.insert(out, reviewer) end
	end
	return out
end

-- The popover's lines, top to bottom. A check that finished while the popover was open stays at the top of Passed.
function M.lines(list: CheckList, pop: Popover, now: number): { Line }
	local out: { Line } = {}
	local function add(line: Line)
		table.insert(out, line)
	end
	local function check(row: CheckRow)
		add({ kind = "check", row = row, sub = M.sub(row, now) })
	end
	local function byName(a: CheckRow, b: CheckRow): boolean
		return a.name < b.name
	end
	for _, group in GROUPS do
		local rows: { CheckRow } = {}
		for _, row in list.rows do
			if row.state == group.state then table.insert(rows, row) end
		end
		table.sort(rows, byName)
		if #rows > 0 then
			add({ kind = "header", label = group.label, count = #rows, skipped = 0 })
			for _, row in rows do check(row) end
		end
	end
	local fresh: { CheckRow }, rest: { CheckRow } = {}, {}
	local passed, skipped = 0, 0
	for _, row in list.rows do
		if row.state == "passed" or row.state == "skipped" then
			if row.state == "passed" then passed += 1 else skipped += 1 end
			table.insert(if pop.seen[row.name] then fresh else rest, row)
		end
	end
	if passed + skipped == 0 then return out end
	-- Passed before skipped, each by name.
	local function done(a: CheckRow, b: CheckRow): boolean
		if a.state ~= b.state then return a.state == "passed" end
		return a.name < b.name
	end
	table.sort(fresh, done)
	table.sort(rest, done)
	add({ kind = "header", label = "Passed", count = passed, skipped = skipped })
	for _, row in fresh do check(row) end
	if pop.passedOpen then
		for _, row in rest do check(row) end
	elseif #rest > 0 then
		add({ kind = "more", count = #rest, fresh = #fresh > 0 })
	end
	return out
end

-- The lines a highlight can rest on, in order.
function M.choices(lines: { Line }): { Line }
	local out: { Line } = {}
	for _, line in lines do
		if line.kind ~= "header" then table.insert(out, line) end
	end
	return out
end

-- Notes the checks not yet finished, so one that finishes while the popover is open stays in sight.
function M.observe(pop: Popover, list: CheckList)
	for _, row in list.rows do
		if row.state == "running" or row.state == "queued" then pop.seen[row.name] = true end
	end
end

-- The check named `name` while it runs again, as a failing step on the fixes page reads it.
function M.rerunning(list: CheckList?, name: string): CheckRow?
	if list == nil then return nil end
	for _, row in list.rows do
		local state = row.state
		if row.name == name and (state == "running" or state == "queued") then return row end
	end
	return nil
end

-- "Re-running 1m 12s", or "Re-running" while it waits for a runner.
function M.rerunText(row: CheckRow, now: number): string
	if row.state == "running" and row.startedAt then return "Re-running " .. M.timeText(row, now) end
	return "Re-running"
end

return M
