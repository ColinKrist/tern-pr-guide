--!strict
-- The PR hub's GitHub boundary. Every GitHub call goes through the injected `Runner` (the real one
-- is `Fetch.runner`, tests pass a fake), JSON text is decoded by the injected `decode`
-- (`Host.json.decode`), and nothing here reads Host, the clock or a file. The parsers take
-- already decoded tables and never throw on a missing field. Each call returns its own rate-limit
-- envelope; the caller sums them. Failures are `Error` values, never thrown.
--
-- Flake evidence is REST (the Actions runs API), so it is the one place here that decodes a body without `data`.
local Checks = require("./hub/checks")
local Fixes = require("./hub/fixes")
local Model = require("./hub/model")

type HubPR = Model.HubPR
type Checks = Model.Checks
type Error = Model.Error
type RateLimit = Model.RateLimit
type Refresh = Model.Refresh
type PRRef = Model.PRRef
type OpenThread = Model.OpenThread
type MergeMethod = Model.MergeMethod
type MergeFailure = Model.MergeFailure
type PendingMerge = Model.PendingMerge
type FixDetails = Fixes.FixDetails

-- What `Host.process.run` gives and takes, minus the `cx`. src/fetch.luau exports the real runner.
export type Out = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Runner = (argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Out) -> ()) -> ()
export type Decode = (text: string) -> any

export type RefreshRequest = { added: { PRRef }, previous: { HubPR }, checkNames: { [string]: boolean }? }
export type Probe = { changed: boolean, lastModified: string?, pollSeconds: number? }
export type ChecksUpdate = { byId: { [string]: { headOid: string, checks: Checks } }, rateLimit: RateLimit }
export type Command = { argv: { string }, stdin: string? }
-- What a repo declares and what its last merges show. `checkedAt` is "" here: the block stamps it, because this module reads no clock.
export type Detected = { declared: MergeMethod?, learned: MergeMethod?, viewerDefault: "squash" | "merge" | "rebase", autoMergeAllowed: boolean, checkedAt: string }

-- One Actions run, as the runs API lists it: the workflow's name, the commit, and how it ended.
export type RunRow = { id: number, workflow: string, sha: string, conclusion: string }
-- A repo's recent runs of its base branch, by workflow name: failures among up to `Model.FLAKE_RUNS` newest.
export type RepoHistory = { base: string, byWorkflow: { [string]: { failed: number, total: number } } }

export type Client = {
	refresh: (req: RefreshRequest, done: (value: Refresh?, err: Error?) -> ()) -> (),
	probe: (since: string?, done: (value: Probe?, err: Error?) -> ()) -> (),
	checkNames: (ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ()) -> (),
	checks: (ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ()) -> (),
	details: (pr: HubPR, done: (value: FixDetails?, err: Error?) -> ()) -> (),
	detect: (repo: string, done: (value: Detected?, err: Error?) -> ()) -> (),
	history: (repo: string, base: string, done: (value: RepoHistory?, err: Error?) -> ()) -> (),
	runs: (repo: string, sha: string, done: (value: { RunRow }?, err: Error?) -> ()) -> (),
	checkList: (prId: string, done: (value: Checks.CheckList?, err: Error?) -> ()) -> (),
	run: (command: Command, done: (stdout: string?, err: Error?) -> ()) -> (),
}

-- Each of these mirrors docs/hub/queries/<file>.graphql without its `#` comment lines;
-- `tools/luau-fixtures --check` fails when they differ.
local HUB_QUERY = [=[
query Hub($q: String!, $n: Int!, $after: String) {
  viewer { login }
  rateLimit { cost remaining resetAt limit used nodeCount }
  mine: search(type: ISSUE, query: $q, first: $n, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ...Hub }
  }
}

fragment Hub on PullRequest {
  id
  number
  title
  url
  isDraft
  createdAt
  updatedAt
  headRefOid
  baseRefName
  additions
  deletions
  changedFiles
  author { __typename login }
  repository { nameWithOwner }
  reviewDecision
  mergeable
  mergeStateStatus
  totalCommentsCount
  autoMergeRequest { enabledAt }
  timelineItems(last: 1, itemTypes: [REMOVED_FROM_MERGE_QUEUE_EVENT]) { nodes { ... on RemovedFromMergeQueueEvent { createdAt reason } } }
  commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state contexts(first: 0) { totalCount checkRunCountsByState { state count } statusContextCountsByState { state count } } } } } }
  latestReviews(first: 20) {
    nodes { author { __typename login } state submittedAt commit { oid } }
  }
  reviewRequests(first: 20) {
    nodes { requestedReviewer {
      __typename
      ... on User { login }
      ... on Team { slug }
    } }
  }
  reviewThreads(first: 100) { totalCount nodes { isResolved } }
  comments(last: 1) { totalCount nodes { updatedAt author { login } } }
}]=]

local THREADS_QUERY = [=[
query Threads($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id number reviewThreads(first: 30) { nodes { isResolved comments(first: 1) { nodes { author { __typename login } } } } } } }
}]=]

local CHECKS_QUERY = [=[
query Checks($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id number headRefOid commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 0) { checkRunCountsByState { state count } statusContextCountsByState { state count } } } } } } } }
}]=]

local CHECK_NAMES_QUERY = [=[
query CheckNames($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id number headRefOid commits(last: 1) { nodes { commit { statusCheckRollup {
    state
    contexts(first: 100) {
      checkRunCountsByState { state count }
      statusContextCountsByState { state count }
      nodes {
        __typename
        ... on CheckRun { name conclusion }
        ... on StatusContext { context state }
      }
    }
  } } } } } }
}]=]

-- These three mirror docs/hub/queries/merge-detect.graphql, merge-failure.graphql and details.graphql the same way.
local MERGE_DETECT_QUERY = [=[
query MergeDetect($owner: String!, $name: String!) {
  rateLimit { cost remaining limit resetAt }
  repository(owner: $owner, name: $name) {
    viewerDefaultMergeMethod
    autoMergeAllowed
    mergeQueue { id }
    aviator: object(expression: "HEAD:.aviator/config.yml") { __typename }
    pullRequests(states: MERGED, first: 8, orderBy: { field: UPDATED_AT, direction: DESC }) {
      nodes { mergedAt mergedBy { __typename login } comments(last: 5) { nodes { createdAt body author { __typename login } } } }
    }
  }
}]=]

local MERGE_FAILURE_QUERY = [=[
query MergeFailure($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id headRefOid
    comments(last: 10) { nodes { createdAt body author { __typename login } } }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 50) { nodes {
      __typename
      ... on CheckRun { name conclusion completedAt }
      ... on StatusContext { context state createdAt }
    } } } } } }
  } }
}]=]

local DETAILS_QUERY = [=[
query Details($id: ID!, $head: String!) {
  rateLimit { cost remaining limit resetAt }
  node(id: $id) { ... on PullRequest {
    id
    headRefOid
    headRefName headRepository { nameWithOwner }
    baseRef { compare(headRef: $head) { behindBy } }
    reviews(last: 20, states: [CHANGES_REQUESTED]) { nodes { author { __typename login } body submittedAt url } }
    commentReviews: reviews(last: 20, states: [COMMENTED]) { nodes { author { __typename login } body submittedAt url commit { oid } } }
    reviewThreads(first: 50) { nodes {
      id isResolved isOutdated path line
      comments(first: 1) { totalCount nodes { author { __typename login } body url diffHunk pullRequestReview { state } } }
    } }
    files(first: 100) { nodes { path } }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 30) { nodes {
      __typename
      ... on CheckRun {
        name conclusion detailsUrl summary
        checkSuite { workflowRun { databaseId workflow { name } } }
        annotations(first: 20) { nodes { path annotationLevel title message location { start { line } } } }
      }
      ... on StatusContext { context state targetUrl }
    } } } } } }
  } }
}]=]

-- This one mirrors docs/hub/queries/check-list.graphql the same way.
local CHECK_LIST_QUERY = [=[
query CheckList($ids: [ID!]!) {
  rateLimit { cost remaining limit resetAt }
  nodes(ids: $ids) { ... on PullRequest { id headRefOid
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
      __typename
      ... on CheckRun { name status conclusion startedAt completedAt detailsUrl checkSuite { app { name } workflowRun { workflow { name } } } }
      ... on StatusContext { context state targetUrl createdAt }
    } } } } } }
  } }
}]=]

-- This one mirrors docs/hub/queries/merged.graphql the same way.
local MERGED_QUERY = [=[
query Merged($q: String!) {
  rateLimit { cost remaining limit resetAt }
  merged: search(type: ISSUE, query: $q, first: 20) { nodes { ... on PullRequest { number title mergedAt repository { nameWithOwner } } } }
}]=]

-- GitHub stops a GraphQL query at about 10 s and answers 502, so a client wait past 30 s is a lost connection.
local GRAPHQL_MS = 30_000
local REST_MS = 30_000
local RUN_MS = 120_000
-- `nodes(ids:)` takes at most 250; a refresh reads the threads of this many PRs and leaves the rest unknown.
local THREAD_IDS_MAX = 100
local NO_LIMIT: RateLimit = { cost = 0, remaining = 0, limit = 0, resetAt = "" }
-- hub-f runs once per search, by the alias `parseHub` reads (HUB_QUERY's is `mine`), all three at once.
local SEARCHES = {
	{ alias = "mine", q = "is:pr is:open author:@me archived:false" },
	{ alias = "requested", q = "is:pr is:open review-requested:@me archived:false" },
	{ alias = "reviewed", q = "is:pr is:open reviewed-by:@me -author:@me archived:false" },
}
-- Recently merged: search can't sort by merge time, but a merge updates the PR, so the most recently updated hold the latest
-- merges. `parseMerged` orders them by `mergedAt` and the board keeps the last 7 days.
local MERGED_SEARCH = "is:pr is:merged author:@me archived:false sort:updated-desc"
-- A search reads up to SEARCH_MAX PRs, PAGE_SIZE at a time: a 20-PR page costs 1 point and about 5 s on busy
-- repos, where 50 at once passes GitHub's limit. A page GitHub drops is asked again at half the size, down to PAGE_MIN.
local SEARCH_MAX = 50
local PAGE_SIZE = 20
local PAGE_MIN = 5

local M = {}

-- Reading decoded JSON without trusting its shape.

local function tbl(value: any): any?
	if type(value) == "table" then return value end
	return nil
end

local function str(value: any): string?
	if type(value) == "string" then return value end
	return nil
end

local function int(value: any): number
	if type(value) == "number" then return value end
	return 0
end

local function list(value: any): { any }
	local t = tbl(value)
	if t == nil then return {} end
	local out = {}
	for _, item in t :: { any } do
		if type(item) == "table" then table.insert(out, item) end
	end
	return out
end

local function rateLimitOf(raw: any): RateLimit?
	local t = tbl(raw)
	if t == nil or type(t.cost) ~= "number" then return nil end
	return { cost = t.cost, remaining = int(t.remaining), limit = int(t.limit), resetAt = str(t.resetAt) or "" }
end

-- Check counts. Skipped and neutral runs pass, as GitHub's own summary counts them.

local FAILING_RUNS = { FAILURE = true, TIMED_OUT = true, STARTUP_FAILURE = true, ACTION_REQUIRED = true, CANCELLED = true }
local PENDING_RUNS = { IN_PROGRESS = true, QUEUED = true, PENDING = true, WAITING = true }
local PASSING_RUNS = { SUCCESS = true, NEUTRAL = true, SKIPPED = true, COMPLETED = true }
local FAILING_STATUSES = { ERROR = true, FAILURE = true }
local PENDING_STATUSES = { PENDING = true, EXPECTED = true }
local ROLLUP_STATES: { [string]: Model.CheckState } = {
	SUCCESS = "passing", FAILURE = "failing", ERROR = "failing", PENDING = "pending", EXPECTED = "pending",
}

local function checksOf(commits: any): Checks
	local none: Checks = { state = "none", passing = 0, failing = 0, pending = 0 }
	local first = list(tbl(commits) and (commits :: any).nodes)[1]
	local commit = first and tbl(first.commit)
	local rollup = commit and tbl(commit.statusCheckRollup)
	if rollup == nil then return none end
	local passing, failing, pending = 0, 0, 0
	local contexts = tbl(rollup.contexts) or {}
	for _, row in list(contexts.checkRunCountsByState) do
		local state, count = str(row.state) or "", int(row.count)
		if FAILING_RUNS[state] then failing += count
		elseif PENDING_RUNS[state] then pending += count
		elseif PASSING_RUNS[state] then passing += count end
	end
	for _, row in list(contexts.statusContextCountsByState) do
		local state, count = str(row.state) or "", int(row.count)
		if FAILING_STATUSES[state] then failing += count
		elseif PENDING_STATUSES[state] then pending += count
		elseif state == "SUCCESS" then passing += count end
	end
	local state = ROLLUP_STATES[str(rollup.state) or ""]
	if state == nil then
		state = if failing > 0 then "failing" elseif pending > 0 then "pending" elseif passing > 0 then "passing" else "none"
	end
	local failedNames: { string }? = nil
	if type(contexts.nodes) == "table" then
		failedNames = {}
		for _, node in contexts.nodes do
			local name = if node.__typename == "CheckRun" and FAILING_RUNS[str(node.conclusion) or ""] then str(node.name)
				elseif node.__typename == "StatusContext" and FAILING_STATUSES[str(node.state) or ""] then str(node.context) else nil
			if name then table.insert(failedNames, name) end
		end
	end
	return { state = state, passing = passing, failing = failing, pending = pending, failedNames = failedNames }
end

-- hub-f

local VERDICTS: { [string]: Model.Verdict } = {
	APPROVED = "approved", CHANGES_REQUESTED = "changes_requested", COMMENTED = "commented", DISMISSED = "dismissed",
}
local DECISIONS = {
	APPROVED = "approved", CHANGES_REQUESTED = "changes_requested", REVIEW_REQUIRED = "review_required",
}

local function lowerFirst(text: string): string
	return string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- The latest time the PR left the merge queue, unless auto-merge was asked for again after that.
local function queueFailure(node: any): Model.MergeFailure?
	local event = list(tbl(node.timelineItems) and node.timelineItems.nodes)[1]
	local removedAt = event and str(event.createdAt)
	if removedAt == nil then return nil end
	local auto = tbl(node.autoMergeRequest)
	local again = auto and str(auto.enabledAt)
	if again and again > removedAt then return nil end
	local why = str(event.reason)
	local reason = "Removed from the merge queue"
	if why and why ~= "" then reason ..= ": " .. lowerFirst(why) end
	return { kind = "queue", reason = reason }
end

local function reviewsOf(node: any, viewer: string): Model.ReviewState
	local latest: { Model.Review } = {}
	local mine: Model.Review? = nil
	for _, row in list(tbl(node.latestReviews) and node.latestReviews.nodes) do
		local author = tbl(row.author)
		local login = author and str(author.login)
		local verdict = VERDICTS[str(row.state) or ""]
		if login and verdict then
			local commit = tbl(row.commit)
			local review: Model.Review = {
				author = login, bot = author.__typename == "Bot", verdict = verdict,
				at = str(row.submittedAt) or "", oid = commit and str(commit.oid) or "",
			}
			if login == viewer then mine = review else table.insert(latest, review) end
		end
	end
	local requested: { string } = {}
	local teams: { string } = {}
	local requestedMe = false
	for _, row in list(tbl(node.reviewRequests) and node.reviewRequests.nodes) do
		local who = tbl(row.requestedReviewer)
		local login, slug = who and str(who.login), who and str(who.slug)
		if login or slug then table.insert(requested, (login or slug) :: string) end
		if slug and not login then table.insert(teams, slug) end
		if login == viewer then requestedMe = true end
	end
	local unresolved = 0
	for _, row in list(tbl(node.reviewThreads) and node.reviewThreads.nodes) do
		if row.isResolved == false then unresolved += 1 end
	end
	local comments = tbl(node.comments)
	return {
		decision = DECISIONS[str(node.reviewDecision) or ""] or "none",
		latest = latest, mine = mine, requestedMe = requestedMe, requested = requested, teams = teams,
		unresolved = unresolved, threads = {}, threadsKnown = unresolved == 0,
		comments = if comments then int(comments.totalCount) else 0,
	}
end

local function prOf(node: any, viewer: string, authored: boolean): HubPR?
	local id, number = str(node.id), node.number
	local repo = tbl(node.repository) and str(node.repository.nameWithOwner)
	if id == nil or type(number) ~= "number" or repo == nil then return nil end
	local author = tbl(node.author)
	local login = author and str(author.login) or "ghost"
	return {
		key = repo .. "#" .. number, id = id, repo = repo, number = number,
		url = str(node.url) or ("https://github.com/" .. repo .. "/pull/" .. number),
		title = str(node.title) or "",
		author = login, authorBot = author ~= nil and author.__typename == "Bot",
		role = if authored or login == viewer then "mine" else "review",
		draft = node.isDraft == true,
		createdAt = str(node.createdAt) or "", lastActivityAt = str(node.updatedAt) or "",
		headOid = str(node.headRefOid) or "", baseBranch = str(node.baseRefName) or "",
		additions = int(node.additions), deletions = int(node.deletions), files = int(node.changedFiles),
		checks = checksOf(node.commits),
		conflicts = node.mergeable == "CONFLICTING", behind = node.mergeStateStatus == "BEHIND",
		reviews = reviewsOf(node, viewer),
		mergeFailure = queueFailure(node), pending = nil,
		tandem = false, addedByMe = false,
	}
end

function M.parseHub(raw: any): { prs: { HubPR }, viewer: string, rateLimit: RateLimit, truncated: boolean }?
	local data = tbl(raw) and tbl(raw.data)
	local viewer = data and tbl(data.viewer) and str(data.viewer.login)
	if data == nil or viewer == nil then return nil end
	local prs: { HubPR } = {}
	local at: { [string]: number } = {}
	local truncated = false
	local function take(node: any, authored: boolean)
		local pr = prOf(node, viewer, authored)
		if pr == nil then return end
		local seen = at[pr.id]
		if seen == nil then
			table.insert(prs, pr)
			at[pr.id] = #prs
		elseif pr.role == "mine" then
			prs[seen].role = "mine"
		end
	end
	for _, name in { "mine", "requested", "reviewed" } do
		local search = tbl(data[name])
		if search then
			if tbl(search.pageInfo) and search.pageInfo.hasNextPage == true then truncated = true end
			for _, node in list(search.nodes) do take(node, name == "mine") end
		end
	end
	-- `added0`, `added1`, …: a PR added by link, as `repository { pullRequest }`.
	local aliases: { string } = {}
	for name in data do
		if string.match(name :: string, "^added%d+$") then table.insert(aliases, name :: string) end
	end
	local function position(name: string): number
		return tonumber(string.sub(name, 6)) or 0
	end
	table.sort(aliases, function(a, b) return position(a) < position(b) end)
	for _, name in aliases do
		local repository = tbl(data[name])
		local node = repository and tbl(repository.pullRequest)
		if node then take(node, false) end
	end
	return { prs = prs, viewer = viewer, rateLimit = rateLimitOf(data.rateLimit) or NO_LIMIT, truncated = truncated }
end

-- merged

-- The Recently merged rows in a merged.graphql answer, newest merge first, or nil without the search.
function M.parseMerged(raw: any): { Model.Opened }?
	local data = tbl(raw) and tbl(raw.data)
	local block = data and tbl(data.merged)
	if block == nil then return nil end
	local out: { Model.Opened } = {}
	for _, node in list(block.nodes) do
		local repo = tbl(node.repository) and str(node.repository.nameWithOwner)
		local at = str(node.mergedAt)
		if repo and at and type(node.number) == "number" then
			table.insert(out, { repo = repo, number = node.number, title = str(node.title) or "", author = "", at = at })
		end
	end
	table.sort(out, function(a: Model.Opened, b: Model.Opened): boolean return a.at > b.at end)
	return out
end

-- threads

function M.parseThreads(raw: any): { threads: { [string]: { OpenThread } }, rateLimit: RateLimit }?
	local data = tbl(raw) and tbl(raw.data)
	if data == nil or tbl(data.nodes) == nil then return nil end
	local threads: { [string]: { OpenThread } } = {}
	for _, node in list(data.nodes) do
		local id = str(node.id)
		if id and tbl(node.reviewThreads) then
			local open: { OpenThread } = {}
			for _, thread in list(node.reviewThreads.nodes) do
				if thread.isResolved == false then
					local first = list(tbl(thread.comments) and thread.comments.nodes)[1]
					local author = first and tbl(first.author)
					table.insert(open, { author = author and str(author.login) or "ghost", bot = author ~= nil and author.__typename == "Bot" })
				end
			end
			threads[id] = open
		end
	end
	return { threads = threads, rateLimit = rateLimitOf(data.rateLimit) or NO_LIMIT }
end

-- checks

function M.parseChecks(raw: any): ChecksUpdate?
	local data = tbl(raw) and tbl(raw.data)
	if data == nil or tbl(data.nodes) == nil then return nil end
	local byId: { [string]: { headOid: string, checks: Checks } } = {}
	for _, node in list(data.nodes) do
		local id = str(node.id)
		if id and tbl(node.commits) then
			byId[id] = { headOid = str(node.headRefOid) or "", checks = checksOf(node.commits) }
		end
	end
	return { byId = byId, rateLimit = rateLimitOf(data.rateLimit) or NO_LIMIT }
end

-- check list

local CONCLUSIONS: { [string]: Checks.CheckState } = {
	SUCCESS = "passed", NEUTRAL = "passed", SKIPPED = "skipped", STALE = "skipped",
	FAILURE = "failing", TIMED_OUT = "failing", CANCELLED = "failing", ACTION_REQUIRED = "failing", STARTUP_FAILURE = "failing",
}
local STATUSES: { [string]: Checks.CheckState } = {
	IN_PROGRESS = "running", QUEUED = "queued", PENDING = "queued", WAITING = "queued", REQUESTED = "queued",
}
local CONTEXT_STATES: { [string]: Checks.CheckState } = {
	SUCCESS = "passed", FAILURE = "failing", ERROR = "failing", PENDING = "running", EXPECTED = "queued",
}

local function checkRow(node: any): Checks.CheckRow?
	if str(node.__typename) == "StatusContext" then
		local name = str(node.context)
		if name == nil then return nil end
		local state = CONTEXT_STATES[str(node.state) or ""] or "queued"
		return { name = name, source = nil, state = state, startedAt = if state == "running" then str(node.createdAt) else nil, completedAt = nil, url = str(node.targetUrl) or "" }
	end
	local name = str(node.name)
	if name == nil then return nil end
	local status = str(node.status) or ""
	local state: Checks.CheckState = if status == "COMPLETED" then (CONCLUSIONS[str(node.conclusion) or ""] or "passed") else (STATUSES[status] or "queued")
	local suite = tbl(node.checkSuite)
	local run = suite and tbl(suite.workflowRun)
	local workflow = run and tbl(run.workflow)
	local app = suite and tbl(suite.app)
	return {
		name = name, source = (workflow and str(workflow.name)) or (app and str(app.name)), state = state,
		startedAt = str(node.startedAt), completedAt = if status == "COMPLETED" then str(node.completedAt) else nil,
		url = str(node.detailsUrl) or "",
	}
end

-- check-list.graphql: every check on the head commit. nil when GitHub sent no pull request.
function M.parseCheckList(raw: any): Checks.CheckList?
	local data = tbl(raw) and tbl(raw.data)
	local node = data and list(data.nodes)[1]
	if node == nil or str(node.headRefOid) == nil then return nil end
	local rows: { Checks.CheckRow } = {}
	local commit = list(tbl(node.commits) and node.commits.nodes)[1]
	local rollup = commit and tbl(commit.commit) and tbl(commit.commit.statusCheckRollup)
	local contexts = rollup and tbl(rollup.contexts)
	for _, context in list(contexts and contexts.nodes) do
		local row = checkRow(context)
		if row then table.insert(rows, row) end
	end
	return { headOid = str(node.headRefOid) :: string, rows = rows }
end

-- probe

-- `gh api -i notifications` output: the status line, then headers, then the body. 304 means nothing changed.
function M.parseProbe(stdout: string): Probe?
	local status = string.match(stdout, "^HTTP/%S+%s+(%d+)")
	if status ~= "200" and status ~= "304" then return nil end
	local probe: Probe = { changed = status == "200", lastModified = nil, pollSeconds = nil }
	local headers = string.match(stdout, "^(.-)\r?\n\r?\n") or stdout
	for line in string.gmatch(headers, "[^\r\n]+") do
		local name, value = string.match(line, "^([%w%-]+):%s*(.-)%s*$")
		if name then
			name = string.lower(name)
			if name == "last-modified" then probe.lastModified = value
			elseif name == "x-poll-interval" then probe.pollSeconds = tonumber(value) end
		end
	end
	return probe
end

-- The fixes page

local function levelOf(raw: any): "failure" | "warning" | "notice"
	if raw == "FAILURE" then return "failure" end
	if raw == "WARNING" then return "warning" end
	return "notice"
end

local function annotationsOf(run: any): { Fixes.Annotation }
	local out: { Fixes.Annotation } = {}
	for _, row in list(tbl(run.annotations) and run.annotations.nodes) do
		local path, message = str(row.path), str(row.message)
		local start = tbl(row.location) and tbl(row.location.start)
		local line = start and start.line
		if path and message and type(line) == "number" then
			local title = str(row.title)
			table.insert(out, { path = path, line = line, level = levelOf(row.annotationLevel), title = if title == "" then nil else title, message = message })
		end
	end
	return out
end

local function failingChecks(node: any): { Fixes.FailingCheck }
	local out: { Fixes.FailingCheck } = {}
	local commit = list(tbl(node.commits) and node.commits.nodes)[1]
	local rollup = commit and tbl(commit.commit) and tbl(commit.commit.statusCheckRollup)
	for _, row in list(rollup and tbl(rollup.contexts) and rollup.contexts.nodes) do
		if row.__typename == "CheckRun" and FAILING_RUNS[str(row.conclusion) or ""] then
			local suite = tbl(row.checkSuite)
			local workflowRun = suite and tbl(suite.workflowRun)
			local workflow = workflowRun and tbl(workflowRun.workflow)
			local runId = workflowRun and workflowRun.databaseId
			table.insert(out, {
				name = str(row.name) or "check", workflow = workflow and str(workflow.name),
				runId = if type(runId) == "number" then runId else nil, url = str(row.detailsUrl) or "",
				summary = str(row.summary), annotations = annotationsOf(row),
			})
		elseif row.__typename == "StatusContext" and FAILING_STATUSES[str(row.state) or ""] then
			table.insert(out, { name = str(row.context) or "status", workflow = nil, runId = nil, url = str(row.targetUrl) or "", summary = nil, annotations = {} })
		end
	end
	return out
end

-- details.graphql for `pr`. `fetchedAt` is "" (the block stamps it), `conflicts` is nil until git has been read,
-- and resolved threads and threads with no comment are left out.
function M.parseDetails(raw: any, pr: HubPR): FixDetails?
	local data = tbl(raw) and tbl(raw.data)
	local node = data and tbl(data.node)
	if node == nil then return nil end
	local reviews: { Fixes.ReviewDetail } = {}
	for _, row in list(tbl(node.reviews) and node.reviews.nodes) do
		local author = tbl(row.author)
		table.insert(reviews, {
			author = author and str(author.login) or "ghost", body = str(row.body) or "",
			at = str(row.submittedAt) or "", url = str(row.url) or pr.url,
		})
	end
	local threads: { Fixes.ThreadDetail } = {}
	for _, row in list(tbl(node.reviewThreads) and node.reviewThreads.nodes) do
		local id = str(row.id)
		local comments = tbl(row.comments)
		local first = list(comments and comments.nodes)[1]
		if id and first and row.isResolved ~= true then
			local author = tbl(first.author)
			local review = tbl(first.pullRequestReview)
			local thread: Fixes.ThreadDetail = {
				id = id, group = if review and review.state == "CHANGES_REQUESTED" then "requested" else "comment",
				author = author and str(author.login) or "ghost", bot = author ~= nil and author.__typename == "Bot",
				path = str(row.path) or "", line = if type(row.line) == "number" then row.line else nil,
				outdated = row.isOutdated == true, body = str(first.body) or "",
				replies = math.max(0, int(comments and comments.totalCount) - 1), url = str(first.url) or pr.url,
				hunk = str(first.diffHunk),
			}
			table.insert(threads, thread)
		end
	end
	local changed: { string } = {}
	for _, row in list(tbl(node.files) and node.files.nodes) do
		local path = str(row.path)
		if path then table.insert(changed, path) end
	end
	-- A bot's comment review with a body but no inline thread: only the bot's newest review, left on this head
	-- (a review with no commit is never trusted), and never a person's (their comment reviews are not requested
	-- changes). Carried as a thread with no path.
	local head = str(node.headRefOid) or pr.headOid
	local newest: { [string]: any } = {}
	local order: { string } = {}
	for _, row in list(tbl(node.commentReviews) and node.commentReviews.nodes) do
		local author = tbl(row.author)
		local login = author and str(author.login)
		if login and author.__typename == "Bot" then
			if newest[login] == nil then table.insert(order, login) end
			newest[login] = row
		end
	end
	for _, login in order do
		local row = newest[login]
		local body = str(row.body) or ""
		local commit = tbl(row.commit)
		local oid = commit and str(commit.oid)
		local text = string.match(body, "^%s*(.-)%s*$") :: string
		local duplicate = false
		for _, thread in threads do
			if thread.author == login and string.match(thread.body, "^%s*(.-)%s*$") == text then duplicate = true end
		end
		if text ~= "" and oid ~= nil and oid == head and not duplicate then
			local url = str(row.url) or pr.url
			table.insert(threads, {
				id = "review:" .. url, group = "comment", author = login, bot = true, path = "", line = nil,
				outdated = false, body = body, replies = 0, url = url, hunk = nil,
			})
		end
	end
	local base = tbl(node.baseRef)
	local compare = base and tbl(base.compare)
	local behindBy = compare and compare.behindBy
	local headRepo = tbl(node.headRepository)
	local repo, branch = headRepo and str(headRepo.nameWithOwner), str(node.headRefName)
	return {
		key = pr.key, headOid = head, fetchedAt = "",
		reviews = reviews, threads = threads, checks = failingChecks(node), changedPaths = changed,
		conflicts = nil, conflictNote = nil, files = nil,
		behindBy = if type(behindBy) == "number" then behindBy else nil,
		branch = if repo and branch then { repo = repo, name = branch } else nil,
	}
end

-- Flake evidence ---------------------------------------------------------------------------------------------

-- `GET repos/{r}/actions/runs`: the finished runs, newest first, as the API sends them. A run with no workflow name or id is dropped.
function M.parseRuns(raw: any): { RunRow }
	local out: { RunRow } = {}
	for _, row in list(tbl(raw) and raw.workflow_runs) do
		local name, sha = str(row.name), str(row.head_sha)
		if name and sha and type(row.id) == "number" then
			table.insert(out, { id = row.id, workflow = name, sha = sha, conclusion = str(row.conclusion) or "" })
		end
	end
	return out
end

-- Per workflow, the failures among its last `Model.FLAKE_RUNS` runs that passed or failed (cancelled and skipped runs
-- say nothing). `base` is only carried along for the reason's wording.
function M.parseHistory(raw: any, base: string): RepoHistory
	local byWorkflow: { [string]: { failed: number, total: number } } = {}
	for _, run in M.parseRuns(raw) do
		local failed = run.conclusion == "failure" or run.conclusion == "timed_out"
		if failed or run.conclusion == "success" then
			local row = byWorkflow[run.workflow] or { failed = 0, total = 0 }
			if row.total < Model.FLAKE_RUNS then
				row.total += 1
				if failed then row.failed += 1 end
			end
			byWorkflow[run.workflow] = row
		end
	end
	return { base = base, byWorkflow = byWorkflow }
end

-- The evidence for one failing check: `history` is the repo's (nil when it couldn't be read), `runs` are the runs of
-- the PR's head commit (nil when unread). Failure text is the summary and every annotation, the runner's own
-- exit-code lines included; the paths are only the ones that say something about code.
function M.evidenceFor(check: Fixes.FailingCheck, changedPaths: { string }, history: RepoHistory?, runs: { RunRow }?): Model.FlakeEvidence
	local text: { string } = { check.summary or "" }
	for _, annotation in check.annotations do
		table.insert(text, (annotation.title or "") .. " " .. annotation.message)
	end
	local paths: { string } = {}
	for _, annotation in Fixes.usable(check.annotations) do
		if table.find(paths, annotation.path) == nil then table.insert(paths, annotation.path) end
	end
	local passed = false
	for _, run in runs or {} do
		if run.workflow == check.workflow and run.conclusion == "success" and run.id ~= check.runId then passed = true end
	end
	local own = if history and check.workflow then history.byWorkflow[check.workflow] else nil
	return {
		history = own, passedBefore = passed, text = table.concat(text, "\n"),
		annotationPaths = paths, changedPaths = changedPaths, base = if history then history.base else nil,
	}
end

-- The history of a repo's base branch changes slowly, so it is read once an hour per repo (and branch), also when
-- the read failed (a failure is not retried inside the hour, and the evidence goes without history). Callers asking
-- while a read is in flight wait for it. `now` is seconds since the epoch, passed in: this module reads no clock.
M.HISTORY_SECONDS = 3600

export type HistoryCache = { read: (repo: string, base: string, now: number, done: (value: RepoHistory?) -> ()) -> () }

function M.historyCache(client: Client): HistoryCache
	local entries: { [string]: { at: number, value: RepoHistory? } } = {}
	local waiting: { [string]: { (value: RepoHistory?) -> () } } = {}
	local function read(repo: string, base: string, now: number, done: (value: RepoHistory?) -> ())
		local key = string.lower(repo) .. "@" .. base
		local entry = entries[key]
		if entry and now - entry.at < M.HISTORY_SECONDS then return done(entry.value) end
		local queue = waiting[key]
		if queue then return table.insert(queue, done) end
		waiting[key] = { done }
		client.history(repo, base, function(value)
			entries[key] = { at = now, value = value }
			local list = waiting[key] or {}
			waiting[key] = nil
			for _, callback in list do callback(value) end
		end)
	end
	return { read = read }
end

-- The client

local function firstLine(text: string): string?
	for line in string.gmatch(text, "[^\r\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") :: string
		if trimmed ~= "" then return (string.gsub(trimmed, "^gh: ", "")) end
	end
	return nil
end

local function limited(text: string): boolean
	return string.find(string.lower(text), "rate limit", 1, true) ~= nil
end

local function failure(operation: string, what: string, reason: string, rateLimit: RateLimit?): Error
	return { operation = operation, message = "Couldn't " .. what .. ": " .. reason, rateLimit = rateLimit }
end

local function rateLimitedMessage(rateLimit: RateLimit?): string
	local resets = if rateLimit and rateLimit.resetAt ~= "" then ", resets at " .. rateLimit.resetAt else ""
	return "GitHub's rate limit is reached" .. resets
end

-- A finished command as decoded JSON, or the `Error` that explains why not. A body with `data`
-- stands even when `gh` exited 1 because of a partial GraphQL error (an added PR that is gone).
local function decoded(out: Out, decode: Decode, operation: string, what: string): (any?, Error?)
	if out.timed_out then return nil, failure(operation, what, "timed out", nil) end
	local doc: any = nil
	if out.stdout ~= "" then
		local ok, value = pcall(decode, out.stdout)
		if ok and type(value) == "table" then doc = value end
	end
	local data = doc and tbl(doc.data)
	local rateLimit = data and rateLimitOf(data.rateLimit)
	local limitedByGithub = limited(out.stderr)
	local errors = doc and list(doc.errors) or {}
	for _, problem in errors do
		if problem.type == "RATE_LIMITED" or limited(str(problem.message) or "") then limitedByGithub = true end
	end
	if limitedByGithub then return nil, failure(operation, what, rateLimitedMessage(rateLimit), rateLimit) end
	if data then return doc, nil end
	local message = errors[1] and str(errors[1].message)
	if message then return nil, failure(operation, what, message, nil) end
	if out.status ~= 0 then
		return nil, failure(operation, what, firstLine(out.stderr) or ("gh exited with status " .. out.status), nil)
	end
	return nil, failure(operation, what, "GitHub sent a response that isn't JSON data", nil)
end

-- A failure worth one more try: our own timeout, a 502, 503 or 504 from GitHub's gateway (its answer to a query
-- that ran past about 10 s), or GitHub's "Something went wrong" body for the same timeout.
local function transient(out: Out): boolean
	if out.timed_out or string.find(out.stderr, "HTTP 50[234]") then return true end
	return string.find(out.stdout, "Something went wrong while executing your query", 1, true) ~= nil
end

local function validRef(ref: PRRef): boolean
	return string.match(ref.repo, "^[%w_.%-]+/[%w_.%-]+$") ~= nil and ref.number > 0 and ref.number % 1 == 0
end

-- hub-f for the search `alias`, with one `pullRequest(number:)` alias per PR added by link, before the fragment.
local function hubQuery(alias: string, added: { PRRef }): string
	local query = if alias == "mine" then HUB_QUERY else (string.gsub(HUB_QUERY, "\n  mine: search%(", "\n  " .. alias .. ": search(", 1))
	local lines: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, ref in added do
		local key = string.lower(ref.repo) .. "#" .. ref.number
		if validRef(ref) and not seen[key] then
			seen[key] = true
			local owner, name = string.match(ref.repo, "^([^/]+)/(.+)$")
			table.insert(lines, string.format('  added%d: repository(owner: "%s", name: "%s") { pullRequest(number: %d) { ...Hub } }', #lines, owner :: string, name :: string, ref.number))
		end
	end
	if #lines == 0 then return query end
	local close = string.find(query, "\n}\n\nfragment", 1, true) :: number
	return string.sub(query, 1, close) .. table.concat(lines, "\n") .. "\n" .. string.sub(query, close + 1)
end

-- Command builders: exact argv, no network. `Client.run` executes them.
local MERGE_FLAGS: { [string]: string } = { squash = "--squash", merge = "--merge", rebase = "--rebase" }

local function prArgv(verb: string, pr: HubPR, ...: string): { string }
	local argv = { "gh", "pr", verb, tostring(pr.number), "--repo", pr.repo }
	for _, word in { ... } do table.insert(argv, word) end
	return argv
end

local REPLY_MUTATION = "mutation($threadId: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) { comment { id url } } }"
local RESOLVE_MUTATION = "mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { thread { id isResolved } } }"

M.commands = {
	-- Merging asks the repo's own tool: GitHub for squash, merge and rebase, `--auto` for the queue, a comment, or a label.
	merge = function(pr: HubPR, method: MergeMethod): Command
		if method.kind == "queue" then return { argv = prArgv("merge", pr, "--auto"), stdin = nil } end
		if method.kind == "comment" then return { argv = prArgv("comment", pr, "--body", method.command), stdin = nil } end
		if method.kind == "label" then return { argv = prArgv("edit", pr, "--add-label", method.label), stdin = nil } end
		return { argv = prArgv("merge", pr, MERGE_FLAGS[method.kind]), stdin = nil }
	end,
	-- Takes back a merge asked for through a queue, a comment (when the method has a cancel) or a label. A GitHub
	-- merge happens at once and has nothing to cancel, so those raise, as does a comment method without a cancel.
	cancelMerge = function(pr: HubPR, method: MergeMethod): Command
		if method.kind == "queue" then return { argv = prArgv("merge", pr, "--disable-auto"), stdin = nil } end
		if method.kind == "comment" and method.cancel then
			return { argv = prArgv("comment", pr, "--body", method.cancel), stdin = nil }
		end
		if method.kind == "label" then return { argv = prArgv("edit", pr, "--remove-label", method.label), stdin = nil } end
		error("commands.cancelMerge: " .. method.kind .. " has nothing to cancel", 0)
	end,
	-- Merge when ready: the merge happens by itself once the PR is approved and green. GitHub's own methods and the
	-- queue use `--auto`; off a queue it needs the repo's method flag too, since `--auto` alone fails there. A comment
	-- or a label is the repo's own command, sent early.
	autoMerge = function(pr: HubPR, method: MergeMethod): Command
		if method.kind == "squash" or method.kind == "merge" or method.kind == "rebase" then
			return { argv = prArgv("merge", pr, "--auto", MERGE_FLAGS[method.kind]), stdin = nil }
		end
		return M.commands.merge(pr, method)
	end,
	-- Asks reviewers (comma-separated logins) to look again.
	requestReview = function(pr: HubPR, login: string): Command
		return { argv = prArgv("edit", pr, "--add-reviewer", login), stdin = nil }
	end,
	-- Closes with no comment; GitHub can reopen it.
	close = function(pr: HubPR): Command
		return { argv = prArgv("close", pr), stdin = nil }
	end,
	-- The branch names and head an agent fix starts from, read again just before it starts.
	refs = function(pr: HubPR): Command
		return { argv = prArgv("view", pr, "--json", "headRefName,baseRefName,headRefOid"), stdin = nil }
	end,
	updateBranch = function(pr: HubPR): Command
		return { argv = { "gh", "pr", "update-branch", tostring(pr.number), "--repo", pr.repo }, stdin = nil }
	end,
	-- Push empty commit, through GitHub's git database so no checkout is needed: the head's tree, a commit of that tree
	-- on the head, then the branch moved to it. `force=false` only fast-forwards, so a branch that moved meanwhile refuses.
	headTree = function(repo: string, oid: string): Command
		return { argv = { "gh", "api", "repos/" .. repo .. "/git/commits/" .. oid, "--jq", ".tree.sha" }, stdin = nil }
	end,
	emptyCommit = function(repo: string, tree: string, parent: string): Command
		return { argv = {
			"gh", "api", "repos/" .. repo .. "/git/commits", "-X", "POST", "-f", "message=Empty commit to re-run checks",
			"-f", "tree=" .. tree, "-f", "parents[]=" .. parent, "--jq", ".sha",
		}, stdin = nil }
	end,
	moveBranch = function(repo: string, branch: string, sha: string): Command
		return { argv = { "gh", "api", "repos/" .. repo .. "/git/refs/heads/" .. branch, "-X", "PATCH", "-f", "sha=" .. sha, "-F", "force=false" }, stdin = nil }
	end,
	-- Replies in a review thread, and resolves one: GraphQL writes, the only way to do either.
	reply = function(pr: HubPR, threadId: string, body: string): Command
		return {
			argv = { "gh", "api", "graphql", "-f", "query=" .. REPLY_MUTATION, "-f", "threadId=" .. threadId, "-f", "body=" .. body },
			stdin = nil,
		}
	end,
	resolve = function(threadId: string): Command
		return { argv = { "gh", "api", "graphql", "-f", "query=" .. RESOLVE_MUTATION, "-f", "threadId=" .. threadId }, stdin = nil }
	end,
}

-- Merge failures and merge habits

local FAILURE_WORDS = {
	"fail", "blocked", "couldn't", "could not", "can't", "cannot", "unable", "conflict", "reject", "dequeue",
	"removed from", "not mergeable", "error",
}
local LEARN_MIN = 3 -- a habit needs this many of the last 8 merges, and more than half of those read

-- The first line that says something: not blank, not an HTML comment or a heading, with leading marks
-- (">", "*", ":x:", emoji) dropped.
local function replyLine(body: string): string?
	for line in string.gmatch(body, "[^\r\n]+") do
		local text = string.match(line, "^%s*(.-)%s*$") :: string
		local skip = text == "" or string.sub(text, 1, 4) == "<!--" or string.sub(text, 1, 1) == "#"
		if not skip then
			text = string.gsub(text, "^:[%w_+%-]+:%s*", "")
			text = string.match(text, "^[^%w]*(.-)$") :: string
			if text ~= "" then
				if #text > 140 then text = string.sub(text, 1, 139) .. "…" end
				return text
			end
		end
	end
	return nil
end

local function mentionsFailure(line: string): boolean
	local lower = string.lower(line)
	for _, word in FAILURE_WORDS do
		if string.find(lower, word, 1, true) then return true end
	end
	return false
end

local function isBot(author: any): boolean
	local who = tbl(author)
	if who == nil then return false end
	local login = string.lower(str(who.login) or "")
	return who.__typename == "Bot" or string.find(login, "bot", 1, true) ~= nil or string.find(login, "aviator", 1, true) ~= nil
end

-- A check that failed after the merge was asked for: its name, the first by name.
local function failedCheck(node: any, since: string): string?
	local commit = list(tbl(node.commits) and node.commits.nodes)[1]
	local rollup = commit and tbl(tbl(commit.commit) and commit.commit.statusCheckRollup)
	local contexts = rollup and tbl(rollup.contexts)
	local found: { string } = {}
	for _, row in list(contexts and contexts.nodes) do
		local name, at, failed
		if row.__typename == "StatusContext" then
			name, at, failed = str(row.context), str(row.createdAt), FAILING_STATUSES[str(row.state) or ""]
		else
			name, at, failed = str(row.name), str(row.completedAt), FAILING_RUNS[str(row.conclusion) or ""]
		end
		if name and failed and at and at > since then table.insert(found, name) end
	end
	table.sort(found)
	return found[1]
end

-- Why a merge asked for at `pending.at` did not happen, from `merge-failure.graphql`'s node for the PR, or nil.
-- Only what came after `pending.at` counts, so asking again clears an old failure. The newest bot reply wins:
-- a reply from Aviator is `aviator`, from any other bot `bot`. Without a reply, a check that failed afterwards is
-- `comment` for a comment merge and `check` for a label merge. A queue's own failures arrive with hub-f.
function M.parseMergeFailure(raw: any, pending: PendingMerge): MergeFailure?
	local node = tbl(raw)
	if node == nil or pending.method == "queue" then return nil end
	local newest: { createdAt: string, line: string, aviator: boolean }? = nil
	for _, row in list(tbl(node.comments) and node.comments.nodes) do
		local at, body = str(row.createdAt), str(row.body)
		local line = if body then replyLine(body) else nil
		if at and at > pending.at and line and isBot(row.author) and (newest == nil or at > newest.createdAt) then
			local who = tbl(row.author)
			local login = string.lower(str(who and who.login) or "")
			newest = { createdAt = at, line = line, aviator = string.find(login, "aviator", 1, true) ~= nil or string.find(string.lower(line), "aviator", 1, true) ~= nil }
		end
	end
	if newest and mentionsFailure(newest.line) then
		return { kind = if newest.aviator then "aviator" else "bot", reason = newest.line }
	end
	local check = failedCheck(node, pending.at)
	if check == nil then return nil end
	if string.find(string.lower(check), "aviator", 1, true) then return { kind = "aviator", reason = check .. " failed" } end
	return { kind = if pending.method == "comment" then "comment" else "check", reason = check }
end

local ENUM_METHODS: { [string]: "squash" | "merge" | "rebase" } = { SQUASH = "squash", MERGE = "merge", REBASE = "rebase" }

-- "/merge" from a comment's first line, when it is a short slash command.
local function slashCommand(body: string): string?
	local line = string.match(body, "^%s*([^\r\n]*)")
	local command = line and string.match(line, "^(/[%w_%-]+[%w_%- ]*)%s*$")
	if command and #command <= 40 then return command end
	return nil
end

-- A repo's declared merge tool and the habit of its last merges. Declared: `.aviator/config.yml` (comment
-- `/aviator merge`, cancelled by `/aviator cancel`), else a merge queue. Learned: a bot merged after a person
-- commented the same slash command, in more than half of the merged PRs and at least LEARN_MIN of them.
function M.parseDetect(raw: any): Detected?
	local data = tbl(raw) and tbl(raw.data)
	local repo = data and tbl(data.repository)
	if data == nil or repo == nil then return nil end
	local declared: MergeMethod? = nil
	if tbl(repo.aviator) then
		declared = { kind = "comment", command = "/aviator merge", cancel = "/aviator cancel" }
	elseif tbl(repo.mergeQueue) then
		declared = { kind = "queue" }
	end
	local merged = list(tbl(repo.pullRequests) and repo.pullRequests.nodes)
	local counts: { [string]: number } = {}
	for _, pr in merged do
		local mergedAt = str(pr.mergedAt)
		if mergedAt and isBot(pr.mergedBy) then
			local latest: string? = nil
			local command: string? = nil
			for _, row in list(tbl(pr.comments) and pr.comments.nodes) do
				local at, body = str(row.createdAt), str(row.body)
				local who = tbl(row.author)
				local slash = if body and not isBot(who) then slashCommand(body) else nil
				if at and slash and at <= mergedAt and (latest == nil or at > latest) then latest, command = at, slash end
			end
			if command then counts[command] = (counts[command] or 0) + 1 end
		end
	end
	local learned: MergeMethod? = nil
	local best, bestCount = nil, 0
	for command, count in counts do
		if count > bestCount or (count == bestCount and best ~= nil and command < best) then best, bestCount = command, count end
	end
	if best and bestCount >= LEARN_MIN and bestCount * 2 > #merged then
		learned = { kind = "comment", command = best, cancel = nil }
	end
	return {
		declared = declared, learned = learned,
		viewerDefault = ENUM_METHODS[str(repo.viewerDefaultMergeMethod) or ""] or "squash",
		autoMergeAllowed = repo.autoMergeAllowed == true, checkedAt = "",
	}
end

function M.client(run: Runner, decode: Decode): Client
	-- Runs `argv` once and hands `done` its result, also when the runner throws.
	local function exec(argv: { string }, opts: { cwd: string?, stdin: string?, timeout_ms: number? }, done: (out: Out) -> ())
		local settled = false
		local ok, err = pcall(run, argv, opts, function(out: Out)
			if settled then return end
			settled = true
			done(out)
		end)
		if not ok then
			if settled then error(err, 0) end
			settled = true
			done({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
		end
	end

	-- A read that fails transiently is run once more. Mutations go through `run`, never here.
	local function graphql(query: string, extra: { string }, operation: string, what: string, done: (doc: any?, err: Error?) -> ())
		local argv = { "gh", "api", "graphql", "-f", "query=" .. query }
		table.move(extra, 1, #extra, #argv + 1, argv)
		local retried = false
		local function attempt()
			exec(argv, { timeout_ms = GRAPHQL_MS }, function(out)
				if transient(out) and not retried then
					retried = true
					return attempt()
				end
				done(decoded(out, decode, operation, what))
			end)
		end
		attempt()
	end


	local HUB_OP, HUB_WHAT = "gh api graphql: hub", "refresh pull requests"

	-- One search of hub-f, page after page up to SEARCH_MAX. `done` gets the search as `{ nodes, pageInfo }`, the
	-- first page's data (the viewer and the added aliases) and every page's envelope.
	local function search(alias: string, q: string, added: { PRRef }, done: (found: any?, first: any?, calls: { RateLimit }, err: Error?) -> ())
		local nodes: { any } = {}
		local calls: { RateLimit } = {}
		local first: any = nil
		local function page(after: string?, size: number)
			local want = math.min(size, SEARCH_MAX - #nodes)
			local argv = { "gh", "api", "graphql", "-f", "query=" .. hubQuery(alias, if first == nil then added else {}), "-f", "q=" .. q, "-F", "n=" .. want }
			if after then
				table.insert(argv, "-f")
				table.insert(argv, "after=" .. after)
			end
			exec(argv, { timeout_ms = GRAPHQL_MS }, function(out)
				if transient(out) and want > PAGE_MIN then return page(after, math.max(PAGE_MIN, want // 2)) end
				local doc, err = decoded(out, decode, HUB_OP, HUB_WHAT)
				if err then return done(nil, nil, calls, err) end
				local data = doc.data
				table.insert(calls, rateLimitOf(data.rateLimit) or NO_LIMIT)
				first = first or data
				local block = tbl(data[alias])
				local info = block and tbl(block.pageInfo)
				for _, node in list(block and block.nodes) do table.insert(nodes, node) end
				local more = info ~= nil and info.hasNextPage == true
				local cursor = info and str(info.endCursor)
				if more and cursor and #nodes < SEARCH_MAX then return page(cursor, want) end
				done({ nodes = nodes, pageInfo = { hasNextPage = more } }, first, calls, nil)
			end)
		end
		page(nil, PAGE_SIZE)
	end

	local function threadsFor(prs: { HubPR }, previous: { HubPR }): { string }
		local known: { [string]: HubPR } = {}
		for _, pr in previous do known[pr.id] = pr end
		local ids: { string } = {}
		for _, pr in prs do
			local before = known[pr.id]
			if pr.reviews.unresolved > 0 then
				if before and before.lastActivityAt == pr.lastActivityAt and before.reviews.threadsKnown then
					pr.reviews.threads = before.reviews.threads
					pr.reviews.threadsKnown = true
				elseif #ids < THREAD_IDS_MAX then
					table.insert(ids, pr.id)
				end
			end
		end
		return ids
	end

	local function idArgs(ids: { string }): { string }
		local args: { string } = {}
		for _, id in ids do
			table.insert(args, "-f")
			table.insert(args, "ids[]=" .. id)
		end
		return args
	end

	local function previousOf(previous: { HubPR }, pr: HubPR): HubPR
		for _, before in previous do
			if before.id == pr.id then return before end
		end
		return pr
	end

	-- PRs with a comment or label merge in flight on the same head commit: the only ones worth a failure lookup.
	-- A queue merge reports its own removal in hub-f, and a new head drops the merge.
	local function inFlightMerges(prs: { HubPR }, previous: { HubPR }): { HubPR }
		local out: { HubPR } = {}
		for _, pr in prs do
			local before = previousOf(previous, pr)
			local pending = before.pending
			if pending and pending.method ~= "queue" and before.headOid == pr.headOid then table.insert(out, pr) end
		end
		return out
	end

	local function checkNames(ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ())
		local combined: ChecksUpdate = { byId = {}, rateLimit = NO_LIMIT }
		local offset = 1
		local function page()
			if offset > #ids then return done(combined, nil) end
			local batch: { string } = {}
			local last = math.min(offset + 9, #ids)
			for i = offset, last do table.insert(batch, ids[i]) end
			graphql(CHECK_NAMES_QUERY, idArgs(batch), "gh api graphql: check names", "read check names", function(doc, err)
				if err then return done(nil, err) end
				local update = M.parseChecks(doc)
				if not update then return done(nil, failure("gh api graphql: check names", "read check names", "GitHub sent a response without nodes", nil)) end
				for id, result in update.byId do combined.byId[id] = result end
				local cost = combined.rateLimit.cost + update.rateLimit.cost
				combined.rateLimit = table.clone(update.rateLimit)
				combined.rateLimit.cost = cost
				offset = last + 1
				page()
			end)
		end
		page()
	end

	local function refresh(req: RefreshRequest, callback: (value: Refresh?, err: Error?) -> ())
		-- The ordinary refresh stays count-only. Named checks cost extra only for configured repositories.
		local function done(value: Refresh?, err: Error?)
			local wanted = req.checkNames
			if not value or not wanted or next(wanted) == nil then return callback(value, err) end
			local selected: { HubPR } = {}
			for _, pr in value.prs do
				if wanted[string.lower(pr.repo)] and pr.checks.state == "failing" then table.insert(selected, pr) end
			end
			local offset = 1
			local function page()
				if offset > #selected then return callback(value, err) end
				local ids: { string } = {}
				local last = math.min(offset + 9, #selected)
				for i = offset, last do table.insert(ids, selected[i].id) end
				checkNames(ids, function(update, namesErr)
					if update then
						for i = offset, last do
							local pr = selected[i]
							local result = update.byId[pr.id]
							if result and result.headOid == pr.headOid then pr.checks = result.checks end
						end
						table.insert(value.calls, update.rateLimit)
						value.rateLimit = update.rateLimit
					elseif namesErr then value.partial = value.partial or namesErr end
					offset = last + 1
					page()
				end)
			end
			page()
		end
		local calls: { RateLimit } = {}
		local merged: { Model.Opened }? = nil
		local function searched(doc: any)
			local hub = M.parseHub(doc)
			if hub == nil then
				return done(nil, failure(HUB_OP, HUB_WHAT, "GitHub sent a response without the viewer", nil))
			end
			local result: Refresh = {
				prs = hub.prs, viewer = hub.viewer, rateLimit = calls[#calls] or NO_LIMIT, calls = calls,
				truncated = hub.truncated, partial = nil, merged = merged,
			}
			local function finish()
				local inFlight = inFlightMerges(hub.prs, req.previous)
				if #inFlight == 0 then return done(result, nil) end
				local ids: { string } = {}
				for _, pr in inFlight do table.insert(ids, pr.id) end
				graphql(MERGE_FAILURE_QUERY, idArgs(ids), "gh api graphql: merge failures", "check merges in flight", function(failDoc, failErr)
					if failErr then
						result.partial = result.partial or failErr
						if failErr.rateLimit then
							table.insert(result.calls, failErr.rateLimit)
							result.rateLimit = failErr.rateLimit
						end
						return done(result, nil)
					end
					local data = tbl(failDoc) and tbl(failDoc.data)
					local byId: { [string]: any } = {}
					for _, node in list(data and data.nodes) do
						local id = str(node.id)
						if id then byId[id] = node end
					end
					for _, pr in inFlight do
						local node, pending = byId[pr.id], previousOf(req.previous, pr).pending
						if node and pending and str(node.headRefOid) == pr.headOid then
							pr.mergeFailure = pr.mergeFailure or M.parseMergeFailure(node, pending)
						end
					end
					local used = rateLimitOf(data and data.rateLimit) or NO_LIMIT
					table.insert(result.calls, used)
					result.rateLimit = used
					done(result, nil)
				end)
			end
			local ids = threadsFor(hub.prs, req.previous)
			if #ids == 0 then return finish() end
			local args = idArgs(ids)
			graphql(THREADS_QUERY, args, "gh api graphql: threads", "read review threads", function(threadsDoc, threadsErr)
				if threadsErr then
					result.partial = threadsErr
					if threadsErr.rateLimit then
						table.insert(result.calls, threadsErr.rateLimit)
						result.rateLimit = threadsErr.rateLimit
					end
					return finish()
				end
				local threads = M.parseThreads(threadsDoc)
				if threads == nil then
					result.partial = failure("gh api graphql: threads", "read review threads", "GitHub sent a response without nodes", nil)
					return finish()
				end
				for _, pr in result.prs do
					local open = threads.threads[pr.id]
					if open then
						pr.reviews.threads = open
						pr.reviews.threadsKnown = true
					end
				end
				table.insert(result.calls, threads.rateLimit)
				result.rateLimit = threads.rateLimit
				finish()
			end)
		end
		-- The searches run at once and meet in one hub-f shaped document; the first failure ends the refresh. Recently merged
		-- runs beside them, and its failure only leaves `merged` nil, so the board keeps the list it had.
		local data: { [string]: any } = {}
		local waiting, failed = #SEARCHES + 1, false
		for i, spec in SEARCHES do
			if failed then break end
			search(spec.alias, spec.q, if i == 1 then req.added else {}, function(found, first, pageCalls, err)
				if failed then return end
				table.move(pageCalls, 1, #pageCalls, #calls + 1, calls)
				if err then
					failed = true
					return done(nil, err)
				end
				data[spec.alias] = found
				for name, value in first do
					if name == "viewer" or string.match(name :: string, "^added%d+$") then data[name] = data[name] or value end
				end
				waiting -= 1
				if waiting == 0 then searched({ data = data }) end
			end)
		end
		if failed then return end
		graphql(MERGED_QUERY, { "-f", "q=" .. MERGED_SEARCH }, "gh api graphql: merged", "read recently merged pull requests", function(doc, err)
			if failed then return end
			if doc then
				merged = M.parseMerged(doc)
				local used = rateLimitOf(tbl(doc.data) and doc.data.rateLimit)
				if used then table.insert(calls, used) end
			end
			waiting -= 1
			if waiting == 0 then searched({ data = data }) end
		end)
	end

	local function probe(since: string?, done: (value: Probe?, err: Error?) -> ())
		local argv = { "gh", "api", "-i", "notifications?per_page=1" }
		if since and since ~= "" then
			table.insert(argv, "-H")
			table.insert(argv, "If-Modified-Since: " .. since)
		end
		exec(argv, { timeout_ms = REST_MS }, function(out)
			local operation, what = "gh api: notifications", "check for changes"
			-- `gh` can exit non-zero on a 304; the status line decides.
			local result = if out.timed_out then nil else M.parseProbe(out.stdout)
			if result then return done(result, nil) end
			if out.timed_out then return done(nil, failure(operation, what, "timed out", nil)) end
			local reason = firstLine(out.stderr) or firstLine(out.stdout) or "no response"
			if limited(out.stderr) or limited(out.stdout) then reason = rateLimitedMessage(nil) end
			done(nil, failure(operation, what, reason, nil))
		end)
	end

	local function checks(ids: { string }, done: (value: ChecksUpdate?, err: Error?) -> ())
		if #ids == 0 then return done({ byId = {}, rateLimit = NO_LIMIT }, nil) end
		local args: { string } = {}
		for _, id in ids do
			table.insert(args, "-f")
			table.insert(args, "ids[]=" .. id)
		end
		graphql(CHECKS_QUERY, args, "gh api graphql: checks", "read checks", function(doc, err)
			if err then return done(nil, err) end
			local update = M.parseChecks(doc)
			if update == nil then
				return done(nil, failure("gh api graphql: checks", "read checks", "GitHub sent a response without nodes", nil))
			end
			done(update, nil)
		end)
	end


	local function details(pr: HubPR, done: (value: FixDetails?, err: Error?) -> ())
		local operation, what = "gh api graphql: details", "read what needs fixing in " .. pr.key
		graphql(DETAILS_QUERY, { "-f", "id=" .. pr.id, "-f", "head=refs/pull/" .. pr.number .. "/head" }, operation, what, function(doc, err)
			if err then return done(nil, err) end
			local found = M.parseDetails(doc, pr)
			if found == nil then return done(nil, failure(operation, what, "GitHub has no pull request " .. pr.key, nil)) end
			done(found, nil)
		end)
	end

	local function checkList(prId: string, done: (value: Checks.CheckList?, err: Error?) -> ())
		local operation, what = "gh api graphql: check list", "load checks"
		graphql(CHECK_LIST_QUERY, { "-f", "ids[]=" .. prId }, operation, what, function(doc, err)
			if err then return done(nil, err) end
			local found = M.parseCheckList(doc)
			if found == nil then return done(nil, failure(operation, what, "GitHub has no pull request with that id", nil)) end
			done(found, nil)
		end)
	end

	local function detect(repo: string, done: (value: Detected?, err: Error?) -> ())
		local owner, name = string.match(repo, "^([%w_.%-]+)/([%w_.%-]+)$")
		if owner == nil or name == nil then
			return done(nil, failure("gh api graphql: merge-detect", "detect how " .. repo .. " merges", "not an owner/repo name", nil))
		end
		graphql(MERGE_DETECT_QUERY, { "-f", "owner=" .. owner, "-f", "name=" .. name }, "gh api graphql: merge-detect", "detect how " .. repo .. " merges", function(doc, err)
			if err then return done(nil, err) end
			local detected = M.parseDetect(doc)
			if detected == nil then
				return done(nil, failure("gh api graphql: merge-detect", "detect how " .. repo .. " merges", "GitHub has no repository " .. repo, nil))
			end
			done(detected, nil)
		end)
	end

	-- A REST body: decoded JSON when it is a table, else the `Error` that says why not.
	local function rest(path: string, operation: string, what: string, done: (doc: any?, err: Error?) -> ())
		exec({ "gh", "api", path }, { timeout_ms = REST_MS }, function(out)
			if out.timed_out then return done(nil, failure(operation, what, "timed out", nil)) end
			local doc: any = nil
			if out.stdout ~= "" then
				local ok, value = pcall(decode, out.stdout)
				if ok and type(value) == "table" then doc = value end
			end
			if limited(out.stderr) or limited(out.stdout) then return done(nil, failure(operation, what, rateLimitedMessage(nil), nil)) end
			if doc and (out.status == 0 or doc.workflow_runs) then return done(doc, nil) end
			done(nil, failure(operation, what, firstLine(out.stderr) or firstLine(out.stdout) or ("gh exited with status " .. out.status), nil))
		end)
	end

	local function history(repo: string, base: string, done: (value: RepoHistory?, err: Error?) -> ())
		local operation, what = "gh api: actions runs", "read recent runs of " .. repo
		if string.match(repo, "^[%w_.%-]+/[%w_.%-]+$") == nil or string.match(base, "^[%w_./%-]+$") == nil then
			return done(nil, failure(operation, what, "not an owner/repo name", nil))
		end
		rest("repos/" .. repo .. "/actions/runs?branch=" .. base .. "&status=completed&per_page=100", operation, what, function(doc, err)
			if err then return done(nil, err) end
			done(M.parseHistory(doc, base), nil)
		end)
	end

	local function runs(repo: string, sha: string, done: (value: { RunRow }?, err: Error?) -> ())
		local operation, what = "gh api: actions runs", "read the runs of " .. string.sub(sha, 1, 7)
		if string.match(repo, "^[%w_.%-]+/[%w_.%-]+$") == nil or string.match(sha, "^%x+$") == nil then
			return done(nil, failure(operation, what, "not an owner/repo name or a commit", nil))
		end
		rest("repos/" .. repo .. "/actions/runs?head_sha=" .. sha .. "&status=completed&per_page=50", operation, what, function(doc, err)
			if err then return done(nil, err) end
			done(M.parseRuns(doc), nil)
		end)
	end

	local function runCommand(command: Command, done: (stdout: string?, err: Error?) -> ())
		local argv = command.argv
		local operation = table.concat(argv, " ", 1, math.min(#argv, 3))
		exec(argv, { stdin = command.stdin, timeout_ms = RUN_MS }, function(out)
			if out.status == 0 and not out.timed_out then return done(out.stdout, nil) end
			local what = "run " .. operation
			if out.timed_out then return done(nil, failure(operation, what, "timed out", nil)) end
			local text = out.stderr .. "\n" .. out.stdout
			local reason = if limited(text) then rateLimitedMessage(nil) else (firstLine(out.stderr) or firstLine(out.stdout) or ("exit status " .. out.status))
			done(nil, failure(operation, what, reason, nil))
		end)
	end

	return { refresh = refresh, probe = probe, checks = checks, checkNames = checkNames, details = details, detect = detect, history = history, runs = runs, checkList = checkList, run = runCommand }
end

return M
