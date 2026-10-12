--!strict
-- The PR hub block: reads its arguments, loads the board's pull requests (for now only the recorded
-- fixture), draws it, and turns clicks and keys into state changes plus the scrolling, focusing and toasts
-- only a live window can do. Clicks (`event`) and keys (`key`) both run one ACTIONS table.
local Agent = require("../agent")
local AgentHost = require("../agent-host")
local AgentRun = require("./agent-run")
local Board = require("../view/hub/board")
local Fetch = require("../fetch")
local Fields = require("../text-field")
local FixesPage = require("../view/hub/fixes")
local Details = require("./details")
local Fixes = require("./fixes")
local Github = require("../github")
local Host = require("../host")
local Keys = require("../keys")
local Model = require("./model")
local Paths = require("../view/hub/paths")
local ReviewFix = require("./review-fix")
local ReviewFixPage = require("../view/hub/review-fix")
local Runtime = require("./runtime")
local Lookups = require("./lookups")
local Refresh = require("./refresh")
local Store = require("./store")
local HubTandem = require("./tandem")
local State = require("./state")
local Sync = require("./sync")
local Summary = require("./summary")

type State = State.State
type Block = Runtime.Block
type AgentFlight = Runtime.AgentFlight
type Replay = Runtime.Replay
type Handler = Runtime.Handler

local FIXTURES = Runtime.FIXTURES
local frameLater, revealSelected, reasonOf, isoNow = Runtime.frameLater, Runtime.revealSelected, Runtime.reasonOf, Runtime.isoNow
local draw = Runtime.draw
local UNCHECKED = Store.UNCHECKED
local TANDEM_OWNS = Store.TANDEM_OWNS
local readCache = Store.readCache
local storedId = Store.storedId
local readLocal = Store.readLocal
local writeAdded = Store.writeAdded
local flagged = Store.flagged
local writeStatus = Store.writeStatus
local joinOwned = Store.joinOwned
local syncOwnership = Store.syncOwnership
local ownershipChecked = Store.ownershipChecked
local keepCache = Store.keepCache
local saveRecord = Lookups.saveRecord
local recordOf = Lookups.recordOf
local loadMerges = Lookups.loadMerges
local detectRepo = Lookups.detectRepo
local setUserMethod = Lookups.setUserMethod
local loadTandem = HubTandem.loadTandem
local beginAgent, advanceAgentFixture = AgentRun.beginAgent, AgentRun.advanceAgentFixture
local readFeedback, openFixes, openReviewFix = Details.readFeedback, Details.openFixes, Details.openReviewFix
local rearm, refetch, refetchSoon, stepFixture = Refresh.rearm, Refresh.refetch, Refresh.refetchSoon, Refresh.stepFixture

local ARGS = "generate=true|false and fixture=<name> (cases, rereview, agent-cards, review-fix, summary)"

-- The recently opened pull requests a fixture board shows, so the fold has rows without a kv store.
local SAMPLE_RECENT: { Sync.Opened } = {
	{ repo = "acme/api", number = 412, title = "Add retry budget to the billing client", author = "dana", at = "2026-10-08T09:12:33Z" },
	{ repo = "acme/web", number = 977, title = "Move the settings tabs into the sidebar", author = "ruben", at = "2026-10-06T16:40:02Z" },
	{ repo = "acme/api", number = 398, title = "Drop the unused webhook table", author = "mei", at = "2026-09-29T11:05:48Z" },
}


-- The agent a fixture board shows, so ⇧M has something to choose from without running omp.
local SAMPLE_AGENT: State.AgentChoice = {
	models = {
		{ selector = "anthropic/claude-opus", name = "claude-opus", efforts = { "low", "medium", "high" } },
		{ selector = "anthropic/claude-sonnet", name = "claude-sonnet", efforts = { "low", "medium", "high" } },
		{ selector = "openai/gpt", name = "gpt", efforts = {} },
	},
	model = "anthropic/claude-opus", effort = "high",
}

-- Reads `name=value` block arguments.
local function options(args: { string }): ({ generate: boolean, fixture: string? }?, string?)
	local out: { generate: boolean, fixture: string? } = { generate = false, fixture = nil }
	for _, arg in args do
		local name, value = string.match(arg, "^(%a+)=(.*)$")
		if name ~= "generate" and name ~= "fixture" then
			return nil, "Unknown argument \"" .. arg .. "\". The block takes " .. ARGS .. "."
		end
		if name == "generate" then
			if value ~= "true" and value ~= "false" then
				return nil, "generate= takes true or false, not \"" .. (value :: string) .. "\". The block takes " .. ARGS .. "."
			end
			out.generate = value == "true"
		elseif FIXTURES[value :: string] == nil then
			return nil, "Unknown fixture \"" .. (value :: string) .. "\". The block takes " .. ARGS .. "."
		else
			out.fixture = value
		end
	end
	return out, nil
end

-- Opens PR `number` of `slug` ("owner/repo") in the guide. The block can't open blocks, so it finds a
-- checkout of the repo (beside the hub's folder, else PR Guide's own copy) and opens a link the window
-- routes to the guide (`State.openPlan`). With no checkout and no copy to make, it says why and opens
-- nothing. A card's open action uses this too.
local function openPr(b: Block, cx: BlockCx, slug: string, number: number, generate: boolean)
	local dir = cx.cwd or Host.getenv("HOME") or ""
	Fetch.checkoutFor(nil, dir, slug, function(found)
		if b.closed then return end
		local _, why = Fetch.savedCopy("github.com", slug)
		local plan = State.openPlan(slug, number, generate, if found then found.root else nil, why, dir)
		if plan.kind == "open" then
			cx:open(plan.url)
		else
			cx:toast("error", plan.text, plan.sub)
		end
	end)
end

-- ⏎ and a double-click open the selected row; ⇧⏎ (or a hub opened for AI guides) starts the AI guide too.
local function openRow(b: Block, cx: BlockCx, value: string, withGuide: boolean)
	local s = b.s
	if value ~= "" then State.select(s, value) end
	local generate = withGuide or b.generate
	local recent = State.selectedRecent(s)
	if recent then return openPr(b, cx, recent.repo, recent.number, generate) end
	local card = State.selectedCard(s)
	if card == nil then return end
	if card.agent and card.agent.kind == "ready" then return openReviewFix(b, cx, card.pr.key) end
	-- A Needs fixes card opens at what needs fixing; the AI guide still opens the whole pull request.
	if card.column == "needs_fixes" and not generate then return openFixes(b, cx, card.pr.key) end
	openPr(b, cx, card.pr.repo, card.pr.number, generate)
end

local function openCard(b: Block, cx: BlockCx, value: string)
	openRow(b, cx, value, false)
end

local function closeMenu(b: Block)
	State.closeMenu(b.s)
end

-- Remembers the agent choice for guides and the hub after the agent menu picked one.
local function keepAgentChoice(b: Block)
	local choice, agent = b.s.agent, b.agent
	if choice and agent then
		agent.model, agent.effort = choice.model, choice.effort
		AgentHost.saveChoice(agent)
	end
end

local chooseMergeRow: (b: Block, cx: BlockCx, index: number) -> ()

-- Chooses the highlighted row: a card's other action runs, a model is remembered.
local function pickRow(b: Block, cx: BlockCx, index: number, ACTIONS: { [string]: Handler })
	local s = b.s
	if s.menu == "actions" then
		local more = State.actionAt(s, index)
		local card = State.selectedCard(s)
		State.closeMenu(s)
		local handler = if more then ACTIONS[more.act] else nil
		if handler and card then handler(b, cx, card.pr.key) end
		return
	end
	if s.menu == "merge" then return chooseMergeRow(b, cx, index) end
	local menu = s.menu
	State.menuPick(s, index)
	if menu == "agent" then keepAgentChoice(b) end
end

local ACTIONS: { [string]: Handler } = {}

-- The window sends this when the hub's pane gains focus; the schedule applies the debounce.
ACTIONS["hub-focused"] = function(b, cx)
	if b.fixture then return end
	State.setRecent(b.s, Fetch.recentPrs())
	b.sched.focusedAt = Host.time()
	rearm(b, cx)
end

-- The window sends this when ⌥⇧⌘R (true) or ⌥⌘R (false) finds the hub already open.
ACTIONS["set-generate"] = function(b, cx, value)
	b.generate = value == "true"
end

ACTIONS["hub-select"] = function(b, cx, key)
	State.select(b.s, key)
end
ACTIONS["hub-open"] = openCard
ACTIONS["hub-open-generate"] = function(b, cx, value)
	openRow(b, cx, value, true)
end
ACTIONS["open"] = openCard
ACTIONS["hub-move"] = function(b, cx, direction)
	if State.move(b.s, direction :: any) then revealSelected(b, cx) end
end
ACTIONS["hub-tab"] = function(b, cx, id)
	if id == "mine" then
		State.setTab(b.s, "mine")
	elseif id == "review" then
		State.setTab(b.s, "review")
	else
		State.switchTab(b.s)
	end
end
ACTIONS["hub-next"] = function(b, cx)
	if State.walk(b.s) then revealSelected(b, cx) end
end
ACTIONS["hub-fold"] = function(b, cx, name)
	State.toggleFold(b.s, name)
end
ACTIONS["hub-escape"] = function(b, cx)
	local s = b.s
	if State.clearMarks(s) then return end
	if s.search.text ~= "" then
		State.setSearch(s, "")
	else
		State.select(s, nil)
	end
end

-- search
ACTIONS["hub-search"] = function(b, cx)
	State.openSearch(b.s)
	frameLater(cx, { { "focus", Paths.searchField } })
end
ACTIONS["hub-searched"] = function(b)
	State.searched(b.s)
end
ACTIONS["hub-search-done"] = function(b)
	State.closeSearch(b.s, false)
end
ACTIONS["hub-search-clear"] = function(b)
	State.closeSearch(b.s, true)
end

-- menus and the key panel
ACTIONS["hub-menu"] = function(b, cx, id)
	local s = b.s
	if s.menu == id then return closeMenu(b) end
	State.openMenu(s, id :: State.MenuId)
end
ACTIONS["hub-actions"] = function(b, cx, key)
	local s = b.s
	State.select(s, key)
	if s.menu == "actions" or s.menu == "merge" then return closeMenu(b) end
	-- A Ready card's only alternative is the merge method, so its ▾ opens the chooser itself.
	local card = State.card(s, key)
	if card and #card.more == 1 and card.more[1].act == "card-method" then return State.openMenu(s, "merge") end
	State.openMenu(s, "actions")
end
ACTIONS["hub-menu-move"] = function(b, cx, delta)
	State.menuMove(b.s, tonumber(delta) or 0)
end
ACTIONS["hub-menu-close"] = function(b)
	closeMenu(b)
end
ACTIONS["hub-menu-pick"] = function(b, cx, index)
	pickRow(b, cx, tonumber(index) or 0, ACTIONS)
end
-- Space chooses the highlighted row (a repository toggles and the menu stays open).
ACTIONS["hub-menu-select"] = function(b, cx)
	pickRow(b, cx, b.s.menuCursor, ACTIONS)
end
-- ⏎ chooses it too, except in the repository list, where it closes the menu on the choices made.
ACTIONS["hub-menu-enter"] = function(b, cx)
	local s = b.s
	local row = State.menuRows(s)[s.menuCursor]
	if s.menu == "repositories" and not (row and row.kind == "clear") then return closeMenu(b) end
	pickRow(b, cx, s.menuCursor, ACTIONS)
end
ACTIONS["hub-menu-effort"] = function(b, cx, delta)
	State.stepEffort(b.s, tonumber(delta) or 0)
	keepAgentChoice(b)
end
ACTIONS["hub-menu-effort-set"] = function(b, cx, level)
	State.setEffort(b.s, level)
	keepAgentChoice(b)
end
ACTIONS["hub-help"] = function(b)
	State.openHelp(b.s)
end
ACTIONS["hub-help-close"] = function(b)
	State.closeHelp(b.s)
end

-- Card actions: shown with their labels and keys; their effects arrive with the changes that build them.
ACTIONS["card-agent"] = function(b, cx, key)
	local pr = State.prOf(b.s, if key ~= "" then key else b.s.selected or "")
	-- One owner per branch: Tandem's PRs are handed to it, never fixed by an agent here.
	if not pr or pr.tandem then return end
	b.botKeys[pr.key] = Model.classify(pr, b.s.now) == "in_review" and State.botActionable(pr)
	beginAgent(b, cx, pr.key, "fix")
end
ACTIONS["card-agent-clone"] = function(b, cx, key) beginAgent(b, cx, key, "clone") end
ACTIONS["card-agent-folder"] = function(b, cx, key) beginAgent(b, cx, key, "folder") end
ACTIONS["card-agent-stop"] = AgentRun.stopAgent
ACTIONS["card-agent-retry"] = AgentRun.retryAgent
ACTIONS["card-agent-worktree"] = AgentRun.openWorktree
ACTIONS["card-summarize"] = function(b, cx, key)
	local s = b.s
	local pr = State.prOf(s, if key ~= "" then key else s.selected or "")
	if b.closed or not pr or s.busy[pr.key] or s.agents[pr.key] then return end
	if not b.fixture and not b.agent then return cx:toast("error", "Couldn't summarize feedback: no agent is available") end
	local signature = State.feedbackSignature(pr)
	State.setBusy(s, pr.key, State.SUMMARIZING)
	draw(b, cx)
	readFeedback(b, pr, function(details, problem)
		if b.closed then return end
		local function complete(text: string?, err: string?)
			if b.closed then return end
			-- A comment edit changes no metadata the board reads, so the answer is installed only after the
			-- feedback is read again and its text is the text that was summarized.
			local function install(fresh: Fixes.FixDetails?, why: string?)
				if b.closed then return end
				State.setBusy(s, pr.key, nil)
				local latest = State.prOf(s, pr.key)
				local current = latest ~= nil and State.feedbackSignature(latest) == signature
				if not text or not details or not fresh or not current or Summary.prompt(fresh) ~= Summary.prompt(details)
					or not State.installSummary(s, fresh, text) then
					cx:toast("error", "Couldn't summarize feedback: " .. reasonOf(err or why or "The answer is incomplete or feedback changed"))
				end
				draw(b, cx)
			end
			if not text or not details then return install(nil, nil) end
			readFeedback(b, pr, install)
		end
		if not details then return complete(nil, problem) end
		if #Summary.authors(details) == 0 then return complete(nil, "No feedback is available") end
		if b.fixture then
			local fixture: any = require("../../fixtures/hub/summary")
			return complete(fixture.answer(details), nil)
		end
		AgentHost.summarizeFeedback(b.agent :: Agent.Agent, Summary.prompt(details), complete)
	end)
end
ACTIONS["card-method"] = function(b, cx, key)
	if not State.card(b.s, key) then return end
	State.select(b.s, key)
	State.openMenu(b.s, "merge")
end

-- ⌘R: refresh now. The sample board steps through its `refreshes` instead of asking GitHub.
ACTIONS["hub-refresh"] = function(b, cx)
	if b.fixture and advanceAgentFixture(b, cx) then return end
	if b.fixture == "agent-cards" then return end
	if b.fixture then return stepFixture(b, cx) end
	refetch(b, cx)
end

ACTIONS["card-handoff"] = HubTandem.handoff
-- Copy link (C): "title url" as plain text, which is all Tern's clipboard takes.
ACTIONS["card-copy"] = function(b, cx, key)
	local card = State.card(b.s, key)
	if not card then return end
	State.select(b.s, key)
	cx:copy(card.pr.title .. " " .. card.pr.url)
	cx:toast("success", "Copied link")
end

-- Merging --------------------------------------------------------------------------------------------------

local MERGE_BUSY = { comment = "Commenting…", label = "Adding label…", queue = "Queuing…" }

-- The repo's resolved method, squash until its record is known.
local function methodOf(b: Block, pr: Model.HubPR): Model.MergeMethod
	local resolved = b.s.merges[pr.repo]
	return if resolved then resolved.method else { kind = "squash" }
end

local function toastDone(cx: BlockCx, pr: Model.HubPR, method: Model.MergeMethod)
	if method.kind == "comment" then
		cx:toast("success", "Commented " .. method.command .. " on #" .. pr.number, pr.title)
	elseif method.kind == "label" then
		cx:toast("success", "Added the " .. method.label .. " label to #" .. pr.number, pr.title)
	elseif method.kind == "queue" then
		cx:toast("success", "Added #" .. pr.number .. " to the merge queue", pr.title)
	else
		cx:toast("success", "Merged #" .. pr.number, pr.title)
	end
end

-- Merges with the repo's method. GitHub's merge happens now and the PR leaves the board; a queue, comment or
-- label hands the merge to the repo's tool, so the card shows it pending until a refresh brings the result.
-- With `done`, the caller owns the toast and the refresh (a batch): it hears nil when the PR merged or was handed to
-- its repo's tool, or the reason it didn't.
local function runMerge(b: Block, cx: BlockCx, pr: Model.HubPR, done: ((err: string?) -> ())?)
	if b.closed then return end
	local s = b.s
	-- A batch reaches here once per PR, long after its dispatch: ownership stored meanwhile joins first, and a store that
	-- cannot be read merges nothing.
	local _, readable = joinOwned(b)
	if not readable then
		if done then return done(UNCHECKED) end
		return cx:toast("error", "Couldn't merge #" .. pr.number .. ": " .. UNCHECKED, pr.repo)
	end
	-- One owner per branch: nothing new merges a PR Tandem watches (a merge already pending is only cancelled).
	-- A batch holds the PRs it captured: the board may have dropped one Tandem took, so the durable set is asked too.
	local owned = State.prOf(s, pr.key)
	if (owned and owned.tandem) or b.watched[string.lower(pr.repo) .. "#" .. pr.number] then
		if done then return done(TANDEM_OWNS) end
		return cx:toast("error", "Couldn't merge #" .. pr.number .. ": " .. TANDEM_OWNS, pr.repo)
	end
	local method = methodOf(b, pr)
	local head = pr.headOid
	local mark = MERGE_BUSY[method.kind] or "Merging…"
	State.setBusy(s, pr.key, mark)
	b.github.run(Github.commands.merge(pr, method), function(_, err)
		if b.closed then return end
		if err then
			State.setBusy(s, pr.key, nil)
			if done then
				done(reasonOf(err.message))
			else
				cx:toast("error", "Couldn't merge #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
			end
		elseif method.kind == "squash" or method.kind == "merge" or method.kind == "rebase" then
			-- The edit below applies only on the head the merge began on, and it is what clears the busy mark there. An adopted
			-- cache that moved the head skips it, so this merge's own mark clears here, and only if nothing newer replaced it.
			if s.busy[pr.key] == mark then State.setBusy(s, pr.key, nil) end
			keepCache(b, cx, function()
				s.acted[pr.key] = true
				State.dropPr(s, pr.key)
			end, pr.key, head)
			-- Adopting another window's cache may have drawn, and the draw closed the block: nothing goes on from here.
			if b.closed then return end
			if done then done(nil) else
				toastDone(cx, pr, method)
				refetchSoon(b, cx)
			end
		else
			State.setBusy(s, pr.key, nil)
			-- One stamp for every application of the edit: a replay must not move it past a bot's later rejection.
			local at = isoNow()
			keepCache(b, cx, function() State.setPending(s, pr.key, { method = method.kind, at = at }) end, pr.key, head, method.kind == "queue")
			if b.closed then return end
			if done then done(nil) else
				toastDone(cx, pr, method)
				refetchSoon(b, cx)
			end
		end
		draw(b, cx)
	end)
end

-- Merge (M): a GitHub method asks first (⌘⏎ merges, Esc cancels); a comment, label or queue runs at once, since
-- it can be cancelled; a comment learned from the repo's history asks once.
ACTIONS["card-merge"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] or card.pr.tandem then return end
	local pr = card.pr
	if not b.fixture and not s.merges[pr.repo] then
		-- Not known yet how this repo merges: GitHub's merge is never the guess.
		State.select(s, key)
		detectRepo(b, cx, pr.repo)
		return cx:toast("info", "Checking how " .. pr.repo .. " merges…", "Try again in a moment")
	end
	if State.mergeStep(s, pr) == "run" then
		State.select(s, key)
		if b.fixture then return cx:toast("info", "The sample board doesn't merge", pr.key) end
		return runMerge(b, cx, pr, nil)
	end
	State.askMerge(s, key)
end

-- Cancel merge (M on a card with a merge in flight): the method's own cancel.
ACTIONS["card-cancel"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	local pending = if card then card.pr.pending else nil
	if not card or not pending or s.busy[key] then return end
	local pr = card.pr
	if b.fixture then return cx:toast("info", "The sample board doesn't cancel merges", pr.key) end
	local method = methodOf(b, pr)
	if pending.method == "queue" then method = { kind = "queue" } end
	local ok, command = pcall(Github.commands.cancelMerge, pr, method)
	if not ok or method.kind ~= pending.method then
		return cx:toast("error", "Couldn't cancel the merge of #" .. pr.number .. ": " .. pr.repo .. " has no way to cancel it", pr.title)
	end
	local head = pr.headOid
	State.setBusy(s, key, "Cancelling…")
	b.github.run(command :: Github.Command, function(_, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if err then
			cx:toast("error", "Couldn't cancel the merge of #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
		else
			keepCache(b, cx, function() State.setPending(s, key, nil) end, key, head)
			if b.closed then return end
			if method.kind == "comment" then
				cx:toast("success", "Commented " .. (method.cancel or "") .. " on #" .. pr.number, pr.title)
			elseif method.kind == "label" then
				cx:toast("success", "Removed the " .. method.label .. " label from #" .. pr.number, pr.title)
			elseif card.column == "in_review" then
				cx:toast("success", "#" .. pr.number .. " won't merge when ready", pr.title)
			else
				cx:toast("success", "Removed #" .. pr.number .. " from the merge queue", pr.title)
			end
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- Merge when ready (M behind the ▾ on an In review card): GitHub's `--auto` with the repo's method flag, or the
-- repo's own command posted early. It can be cancelled, so it asks nothing. The card then reads "Merges when ready".
ACTIONS["card-auto"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] or card.pr.pending or card.pr.tandem then return end
	local pr = card.pr
	State.select(s, key)
	if b.fixture then return cx:toast("info", "The sample board doesn't merge", pr.key) end
	if not ownershipChecked(b, cx, "set #" .. pr.number .. " to merge when ready") then return end
	if pr.tandem then return cx:toast("error", "Couldn't set #" .. pr.number .. " to merge when ready: " .. TANDEM_OWNS, pr.repo) end
	if not Model.canMergeWhenReady(s.merges[pr.repo], s.autoMerge[pr.repo]) then
		return cx:toast("error", "Couldn't set #" .. pr.number .. " to merge when ready: " .. pr.repo .. " doesn't allow auto-merge", pr.title)
	end
	local method = methodOf(b, pr)
	local head = pr.headOid
	State.setBusy(s, key, MERGE_BUSY[method.kind] or "Setting…")
	b.github.run(Github.commands.autoMerge(pr, method), function(_, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if err then
			cx:toast("error", "Couldn't set #" .. pr.number .. " to merge when ready: " .. reasonOf(err.message), pr.repo)
		else
			local kind = if method.kind == "comment" or method.kind == "label" then method.kind else "queue"
			local at = isoNow()
			keepCache(b, cx, function() State.setPending(s, key, { method = kind, at = at }) end, key, head, kind == "queue")
			if b.closed then return end
			cx:toast("success", "#" .. pr.number .. " will merge when ready", pr.title)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- Re-request review (Q on a card that waits on a re-review): asks the reviewers whose changes the push answers.
ACTIONS["card-rerequest"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] then return end
	local pr = card.pr
	local again = Model.awaitingReReview(pr)
	if not again or #again.ask == 0 then return end
	State.select(s, key)
	if b.fixture then return cx:toast("info", "The sample board doesn't ask for reviews", pr.key) end
	local logins = again.ask
	local head = pr.headOid
	State.setBusy(s, key, "Requesting…")
	b.github.run(Github.commands.requestReview(pr, table.concat(logins, ",")), function(_, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if err then
			cx:toast("error", "Couldn't re-request review on #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
		else
			keepCache(b, cx, function() State.reRequested(s, key, logins) end, key, head)
			if b.closed then return end
			cx:toast("success", "Asked " .. Model.reviewerList(logins) .. " to review #" .. pr.number .. " again", pr.title)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

chooseMergeRow = function(b, cx, index)
	local s = b.s
	local kind = s.menu == "merge" and State.MERGE_KINDS[index] or nil
	local repo = State.mergeRepo(s)
	if not kind or not repo then return end
	if kind.id == "comment" or kind.id == "label" then
		s.menuCursor = index
		return State.beginMethodEdit(s, kind.id)
	end
	setUserMethod(b, cx, repo, { kind = kind.id } :: any)
	State.closeMenu(s)
end

ACTIONS["hub-method-save"] = function(b, cx)
	local s = b.s
	local edit = s.methodEdit
	local method = State.methodOfEdit(s)
	if not edit or not method then return end
	setUserMethod(b, cx, edit.repo, method)
	State.closeMenu(s)
end
ACTIONS["hub-method-cancel"] = function(b)
	State.cancelMethodEdit(b.s)
end

-- Select several -------------------------------------------------------------------------------------------

-- Space on the selected card, or a ⌘/⇧-click on `value`: selects it for Merge selected or Close stale.
ACTIONS["hub-mark"] = function(b, cx, value)
	local s = b.s
	local key = if value ~= "" then value else s.selected
	if not key then return end
	local ok, why = State.toggleMark(s, key)
	if ok then return end
	local card = State.card(s, key)
	if card then cx:toast("info", "Can't select #" .. card.pr.number .. ": " .. (why or "it isn't selectable"), card.pr.title) end
end

-- ⇧X and the Inactive fold's Close stale: selects every stale pull request that isn't a draft.
ACTIONS["hub-mark-stale"] = function(b, cx)
	if State.markStale(b.s) == 0 then cx:toast("info", "No stale pull requests to close", "Drafts are selected one by one with Space") end
end

ACTIONS["hub-marks-clear"] = function(b)
	State.clearMarks(b.s)
end

-- A repo whose merge method isn't known yet is looked up first: GitHub's merge is never the guess.
ACTIONS["hub-batch-merge"] = function(b, cx)
	local s = b.s
	if s.mode ~= "board" or State.selection(s) == nil then return end
	if not b.fixture then
		local waiting = false
		for _, card in State.markedCards(s) do
			if not s.merges[card.pr.repo] then
				waiting = true
				detectRepo(b, cx, card.pr.repo)
			end
		end
		if waiting then return cx:toast("info", "Checking how these repositories merge…", "Try again in a moment") end
	end
	State.askBatch(s, "ready")
end
ACTIONS["hub-batch-close"] = function(b)
	local s = b.s
	if s.mode == "board" then State.askBatch(s, "inactive") end
end

local function refList(prs: { Model.HubPR }): string
	local out: { string } = {}
	for _, pr in prs do table.insert(out, "#" .. pr.number) end
	return table.concat(out, ", ")
end

-- Runs the confirmed selection one pull request at a time, in column order. A failure stops the rest, which stay
-- selected; one toast names what went through and what didn't.
local function runBatch(b: Block, cx: BlockCx, keys: { string }, merge: boolean)
	local s = b.s
	if b.fixture then return cx:toast("info", if merge then "The sample board doesn't merge" else "The sample board doesn't close pull requests") end
	local queue: { Model.HubPR } = {}
	for _, key in keys do
		local card = State.card(s, key)
		if card and not s.busy[key] then table.insert(queue, card.pr) end
	end
	if #queue == 0 then return end
	local finished: { Model.HubPR } = {}
	local handed = false -- some went to a repo's tool (comment, label, queue) rather than merging at once
	local step: (index: number) -> ()
	local function finish(failed: Model.HubPR?, reason: string?)
		if b.closed then return end
		local rest: { Model.HubPR } = {}
		for i = #finished + 1, #queue do table.insert(rest, queue[i]) end
		local done = if merge then (if handed then "Asked to merge " else "Merged ") else "Closed "
		if failed and reason then
			local text = (if #finished > 0 then done .. refList(finished) .. ". " else "") .. "Couldn't " .. (if merge then "merge" else "close") .. " #" .. failed.number .. ": " .. reason
			cx:toast("error", text, "Not " .. (if merge then "merged" else "closed") .. ": " .. refList(rest) .. ". Still selected.")
		else
			local n = #finished
			local noun = if n == 1 then "pull request" else "pull requests"
			cx:toast("success", done .. n .. " " .. noun, nil)
		end
		refetchSoon(b, cx)
		draw(b, cx)
	end
	step = function(index: number)
		if b.closed then return end
		local pr = queue[index]
		if not pr then return finish(nil, nil) end
		local function after(err: string?)
			-- A redraw while keeping the cache may have closed the block: no next command, no toast.
			if b.closed then return end
			if err then return finish(pr, err) end
			table.insert(finished, pr)
			s.marked[pr.key] = nil
			step(index + 1)
		end
		if merge then
			local kind = methodOf(b, pr).kind
			if kind ~= "squash" and kind ~= "merge" and kind ~= "rebase" then handed = true end
			runMerge(b, cx, pr, after)
			return
		end
		local head = pr.headOid
		State.setBusy(s, pr.key, "Closing…")
		b.github.run(Github.commands.close(pr), function(_, err)
			if b.closed then return end
			State.setBusy(s, pr.key, nil)
			if err then return after(reasonOf(err.message)) end
			keepCache(b, cx, function()
				s.acted[pr.key] = true
				State.dropPr(s, pr.key)
			end, pr.key, head)
			after(nil)
		end)
	end
	step(1)
end

-- Esc on the learned-method question declines it for good: the repo is not asked again.
ACTIONS["hub-confirm-cancel"] = function(b, cx)
	local s = b.s
	local confirm = s.confirm
	local card = if confirm and confirm.kind == "learned" then State.card(s, confirm.keys[1]) else nil
	State.cancelConfirm(s)
	if not card then return end
	local record = recordOf(b, card.pr.repo)
	record.learnedAnswered = true
	saveRecord(b, card.pr.repo, record)
	cx:toast("info", "Won't suggest that again for " .. card.pr.repo)
end
ACTIONS["hub-confirm"] = function(b, cx)
	local s = b.s
	local confirm = s.confirm
	local card = if confirm and (confirm.kind == "merge" or confirm.kind == "learned") then State.card(s, confirm.keys[1]) else nil
	local learned = confirm ~= nil and confirm.kind == "learned"
	if confirm and (confirm.kind == "batch-merge" or confirm.kind == "batch-close") then
		local keys = confirm.keys
		State.cancelConfirm(s)
		return runBatch(b, cx, keys, confirm.kind == "batch-merge")
	end
	State.cancelConfirm(s)
	if not card then return end
	local resolved = s.merges[card.pr.repo]
	-- Saying yes to the suggestion makes it the viewer's own setting.
	if learned and resolved then setUserMethod(b, cx, card.pr.repo, resolved.method) end
	if b.fixture then return cx:toast("info", "The sample board doesn't merge", card.pr.key) end
	runMerge(b, cx, card.pr, nil)
end

-- Update branch (U): a Ready card that is behind main. Its checks run again, so the card waits on them.
local UPDATE_BUSY = "Updating…"

ACTIONS["card-update"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or s.busy[key] then return end
	local pr = card.pr
	if not ownershipChecked(b, cx, "update #" .. pr.number) then return end
	-- One owner per branch: a queued Update branch for a PR Tandem took meanwhile sends nothing.
	if pr.tandem then return cx:toast("error", "Couldn't update #" .. pr.number .. ": " .. TANDEM_OWNS, pr.repo) end
	if not pr.behind or pr.conflicts then return cx:toast("info", "#" .. pr.number .. " isn't behind " .. pr.baseBranch, pr.key) end
	if b.fixture then return cx:toast("info", "The sample board doesn't update branches", pr.key) end
	local head = pr.headOid
	State.setBusy(s, key, UPDATE_BUSY)
	b.github.run(Github.commands.updateBranch(pr), function(_, err)
		if b.closed then return end
		if err then
			State.setBusy(s, key, nil)
			cx:toast("error", "Couldn't update #" .. pr.number .. ": " .. reasonOf(err.message), pr.repo)
		else
			-- The edit below applies only on the head the update began on, and it is what clears the busy mark there. An adopted
			-- cache that moved the head skips it, so this update's own mark clears here, and only if nothing newer replaced it.
			if s.busy[key] == UPDATE_BUSY then State.setBusy(s, key, nil) end
			keepCache(b, cx, function()
				s.acted[key] = true
				State.branchUpdated(s, key)
			end, key, head)
			if b.closed then return end
			cx:toast("success", "Updated #" .. pr.number .. " with " .. pr.baseBranch)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- Re-run failed checks (⇧R, behind Fix checks ▾): `gh run rerun <id> --failed` for each failing workflow run of the
-- card, one at a time. Only a press runs it. The runs come from the evidence on hand, else from the details.
ACTIONS["card-rerun"] = function(b, cx, key)
	local s = b.s
	local pr = State.prOf(s, key)
	if pr == nil or s.busy[key] then return end
	if b.fixture then return cx:toast("info", "The sample board doesn't re-run checks", pr.key) end
	if pr.checks.failing == 0 then return cx:toast("info", "#" .. pr.number .. " has no failing checks", pr.key) end
	local function fail(reason: string)
		State.setBusy(s, key, nil)
		cx:toast("error", "Couldn't re-run checks on #" .. pr.number .. ": " .. reasonOf(reason), pr.repo)
		draw(b, cx)
	end
	local function go(ids: { number })
		if #ids == 0 then return fail("GitHub lists no workflow run for the failing checks") end
		State.setBusy(s, key, "Re-running…")
		draw(b, cx)
		local function step(i: number)
			if b.closed then return end
			if i > #ids then
				State.setBusy(s, key, nil)
				b.flakeTried[pr.key .. "@" .. pr.headOid] = nil
				State.setFlake(s, key, nil)
				cx:toast("success", "Re-running failed checks on #" .. pr.number, pr.repo)
				refetchSoon(b, cx)
				return draw(b, cx)
			end
			b.github.run(Github.commands.rerun(pr.repo, ids[i]), function(_, err)
				if b.closed then return end
				if err then return fail(err.message) end
				step(i + 1)
			end)
		end
		step(1)
	end
	local known = State.flakeOf(s, key)
	if known and #known.runs > 0 then return go(known.runs) end
	State.setBusy(s, key, "Reading checks…")
	draw(b, cx)
	b.github.details(pr, function(d, err)
		if b.closed then return end
		State.setBusy(s, key, nil)
		if d == nil then return fail(if err then err.message else "no answer") end
		local ids: { number } = {}
		for _, check in d.checks do
			if check.runId and table.find(ids, check.runId) == nil then table.insert(ids, check.runId) end
		end
		go(ids)
	end)
end

-- Add by link (N) ---------------------------------------------------------------------------------------

ACTIONS["hub-link"] = function(b, cx)
	State.openLink(b.s)
	frameLater(cx, { { "focus", Paths.linkField } })
end
ACTIONS["hub-link-clear"] = function(b)
	State.closeLink(b.s, true)
end

-- ⏎: add a new pull request to Review requests, or show one the board already has.
ACTIONS["hub-link-add"] = function(b, cx)
	local s = b.s
	local target = State.linkTarget(s)
	if target.kind == "board" then
		State.closeLink(s, true)
		if State.show(s, target.pr.key) then revealSelected(b, cx) end
	elseif target.kind == "new" then
		local ref: Model.PRRef = { repo = target.repo, number = target.number }
		if b.fixture then return cx:toast("info", "The sample board doesn't add pull requests") end
		local added, why = State.withAdded(readLocal().added, ref)
		local problem = why or (if added then writeAdded(added) else nil)
		if problem then return cx:toast("error", "Couldn't add #" .. ref.number .. ": " .. problem, ref.repo) end
		State.closeLink(s, true)
		b.show = ref
		cx:toast("info", "Adding #" .. ref.number .. " to Review requests…", ref.repo)
		refetch(b, cx)
	end
end

-- ⇧⏎: open it without adding it.
ACTIONS["hub-link-open"] = function(b, cx)
	local target = State.linkTarget(b.s)
	if target.kind == "board" or target.kind == "new" then
		State.closeLink(b.s, true)
		openPr(b, cx, target.repo, target.number, b.generate)
	end
end

-- Remove from Review requests (X): only on a pull request added by link.
ACTIONS["card-remove"] = function(b, cx, key)
	local s = b.s
	local card = State.card(s, key)
	if not card or not card.pr.addedByMe then return end
	local pr = card.pr
	if not b.fixture then
		local added = readLocal().added
		for at, ref in added do
			if ref.number == pr.number and string.lower(ref.repo) == string.lower(pr.repo) then added[at] = nil end
		end
		local why = writeAdded(added)
		if why then return cx:toast("error", "Couldn't remove #" .. pr.number .. ": " .. why, pr.repo) end
	end
	keepCache(b, cx, function() State.unadd(s, key) end, key, pr.headOid)
	if b.closed then return end
	cx:toast("info", "Removed #" .. pr.number .. " from Review requests", pr.repo)
	refetch(b, cx)
end

ACTIONS["review-fix-close"] = function(b, cx)
	if not b.s.route or b.s.route.kind ~= "review-fix" then return end
	local page = State.reviewPage(b.s)
	if page and (page.busy or page.ask) then return end
	State.closeFixes(b.s)
	revealSelected(b, cx)
end
ACTIONS["review-fix-step"] = function(b, _, index) State.reviewSelect(b.s, tonumber(index) or 1) end
ACTIONS["review-fix-move"] = function(b, _, delta)
	local page = State.reviewPage(b.s)
	if page then State.reviewSelect(b.s, page.cur + (tonumber(delta) or 0)) end
end
ACTIONS["review-fix-reviewed"] = function(b, _, index) State.reviewToggle(b.s, tonumber(index)) end
ACTIONS["review-fix-original"] = function(b) State.reviewOriginal(b.s) end
ACTIONS["review-fix-discard"] = function(b, cx)
	local page = State.reviewPage(b.s)
	if page and page.completion == "push" then return cx:toast("error", "Couldn't discard the fix: return the worktree lease first") end
	State.reviewAsk(b.s, true)
end
ACTIONS["review-fix-discard-cancel"] = function(b) State.reviewAsk(b.s, false) end

local function reviewEffect(b: Block, cx: BlockCx, action: "push" | "discard")
	local page, request = State.reviewPage(b.s), State.reviewRequest(b.s)
	if not page or page.busy then return end
	local verb = if action == "push" then "push" else "discard"
	if not request then return cx:toast("error", "Couldn't " .. verb .. " the fix: wait for the fix to load") end
	if action == "push" and page.ask then return end
	local plan, problem = ReviewFix.plan(action, request, page.ask)
	if not plan then return cx:toast("error", "Couldn't " .. verb .. " the fix: " .. (problem or "no action is available")) end
	local agent = b.s.agents[request.key]
	if not agent or agent.kind ~= "ready" or agent.fix ~= request.fix then return end
	local flight = if b.agentFlight and b.agentFlight.key == request.key then b.agentFlight else nil
	if not b.fixture then
		local lease = if flight and flight.engine then flight.engine.held() else nil
		if not flight or flight.key ~= request.key or not flight.settled or flight.starting or flight.releasing or not lease or lease.path ~= request.fix.worktree then
			return cx:toast("error", "Couldn't " .. verb .. " the fix: the worktree lease is unavailable")
		end
	end
	-- One owner per branch: no push begins on a PR Tandem watches, or when that could not be checked. The ready fix and its
	-- lease stay for Discard.
	if action == "push" and plan.command and not ownershipChecked(b, cx, "push the fix") then return end
	local owner = State.prOf(b.s, request.key)
	if action == "push" and plan.command and owner and owner.tandem then
		return cx:toast("error", "Couldn't push the fix: " .. TANDEM_OWNS)
	end
	local route = b.s.route :: State.Route
	route.ask, route.error = false, nil
	State.setBusy(b.s, request.key, if action == "push" and plan.command then "Pushing fix…" else "Returning worktree lease…")
	draw(b, cx)
	local pushed = action == "push" and agent.completion == "push"
	local function fail(reason: string)
		State.setBusy(b.s, request.key, nil)
		if b.s.route == route then route.error = "Couldn't " .. verb .. " the fix: " .. reasonOf(reason) end
		if not b.closed then
			cx:toast("error", "Couldn't " .. verb .. " the fix: " .. reasonOf(reason))
			draw(b, cx)
		end
	end
	local function release()
		-- Completion is retained on the ready fix. P then retries only this return,
		-- while a failed Discard asks again and retries the same engine's guarded reset.
		agent.completion = action
		State.setBusy(b.s, request.key, "Returning worktree lease…")
		if not b.closed then draw(b, cx) end
		local called = false
		if flight then flight.releasing = true end
		local function returned(ok: boolean?, err: string?)
			if called then return end
			called = true
			if flight then flight.releasing = false end
			local engine = if flight then flight.engine else nil
			if ok and not b.fixture and (not engine or engine.held() ~= nil or engine.busy()) then ok, err = nil, "The engine still holds the worktree lease" end
			local outcome = ReviewFix.result(plan :: ReviewFix.Plan, pushed, ok == true)
			if not outcome.clear then return fail(err or "The worktree lease could not be returned") end
			if b.s.agents[request.key] ~= agent then return end
			b.s.agents[request.key], b.s.busy[request.key] = nil, nil
			if b.agentFlight == flight then b.agentFlight = nil end
			if action == "push" then
				local pr = State.prOf(b.s, request.key)
				if pr then pr.headOid, pr.conflicts = request.fix.commit, false end
				b.s.acted[request.key] = true
				State.branchUpdated(b.s, request.key)
			else State.project(b.s) end
			if b.s.route == route then State.closeFixes(b.s) end
			if not b.closed then
				cx:toast("success", if action == "push" then "Pushed the fix to #" .. request.number else "Discarded the fix for #" .. request.number)
				draw(b, cx)
				revealSelected(b, cx)
				if action == "push" then refetch(b, cx) end
			end
		end
		if b.fixture then returned(true, nil); return end
		local ok, err = pcall(AgentHost.returnAgentFix, request.fix.worktree, returned)
		if not ok then returned(nil, tostring(err)) end
	end
	if action == "discard" or not plan.command then release(); return end
	local called = false
	local unchecked = false
	local function completed(ok: boolean?, err: string?)
		if called then return end
		called = true
		if not ok then
			local current = State.prOf(b.s, request.key)
			return fail(if current and current.tandem then TANDEM_OWNS elseif unchecked then UNCHECKED else err or "Git refused the push")
		end
		pushed = true
		release()
	end
	if b.fixture then completed(true, nil); return end
	-- Fetch asks this before every command of the push, the remote reads too: a PR Tandem takes meanwhile is never pushed to.
	local function canPush(): boolean
		local _, readable = syncOwnership(b, cx)
		unchecked = not readable
		local current = b.s.agents[request.key]
		local pr = State.prOf(b.s, request.key)
		return readable and not b.closed and b.agentFlight == flight and current ~= nil and current == agent and current.kind == "ready"
			and current.fix == request.fix and b.s.selected == request.key and b.s.route == route
			and route.kind == "review-fix" and State.reviewed(current.fix, current.reviewed)
			and pr ~= nil and not pr.tandem and pr.repo == request.repo and pr.number == request.number
			and (pr.headOid == request.fix.headOid or pr.headOid == request.fix.commit)
	end
	local ok, err = pcall(AgentHost.pushAgentFix, plan, canPush, completed)
	if not ok then completed(nil, tostring(err)) end
end
ACTIONS["review-fix-push"] = function(b, cx) reviewEffect(b, cx, "push") end
ACTIONS["review-fix-discard-confirm"] = function(b, cx) reviewEffect(b, cx, "discard") end

ACTIONS["fixes-close"] = function(b)
	State.closeFixes(b.s)
end
ACTIONS["fixes-step"] = function(b, cx, index)
	State.fixSelect(b.s, tonumber(index) or 1)
	State.fixFocus(b.s, "steps")
end
ACTIONS["fixes-move"] = function(b, cx, delta)
	State.fixMove(b.s, tonumber(delta) or 0)
end
ACTIONS["fixes-focus"] = function(b, cx, where)
	State.fixFocus(b.s, if where == "panel" then "panel" else "steps")
end
ACTIONS["fixes-bots"] = function(b)
	State.fixToggleBots(b.s)
end

-- The page's pull request and the thread of the step on show, when it has one.
local function fixTarget(b: Block): (State.Route?, Model.HubPR?, Fixes.Step?)
	local s = b.s
	local route = s.route
	if route == nil then return nil, nil, nil end
	return route, State.prOf(s, route.key), State.fixStep(s)
end

ACTIONS["fixes-reply"] = function(b, cx)
	local route, _, step = fixTarget(b)
	if route == nil or step == nil or step.thread == nil then return end
	if route.resolved[step.thread.id] then return cx:toast("info", "This thread is resolved", step.thread.path) end
	if State.beginReply(b.s) then frameLater(cx, { { "focus", Paths.replyField } }) end
end
ACTIONS["fixes-cancel"] = function(b)
	State.cancelReply(b.s)
end
ACTIONS["fixes-post"] = function(b, cx)
	local route, pr, step = fixTarget(b)
	if route == nil or pr == nil or step == nil or step.thread == nil or route.reply == nil or route.busy then return end
	local thread = step.thread
	local text = string.match(route.reply.text, "^%s*(.-)%s*$") :: string
	if text == "" then return cx:toast("error", "Couldn't post the reply: it's empty", pr.key) end
	local function posted()
		route.busy = false
		local list = route.replies[thread.id] or {}
		table.insert(list, text)
		route.replies[thread.id] = list
		route.reply = nil
		if b.s.mode == "reply" then b.s.mode = "fixes" end
		cx:toast("success", "Replied to @" .. thread.author, pr.key)
	end
	if b.fixture then return posted() end
	route.busy = true
	b.github.run(Github.commands.reply(pr, thread.id, text), function(_, err)
		if b.closed then return end
		if err then
			route.busy = false
			cx:toast("error", err.message, pr.key)
		else
			posted()
		end
		draw(b, cx)
	end)
end
ACTIONS["fixes-resolve"] = function(b, cx)
	local route, pr, step = fixTarget(b)
	if route == nil or pr == nil or step == nil or step.thread == nil or route.busy then return end
	local thread = step.thread
	if route.resolved[thread.id] then return cx:toast("info", "This thread is already resolved", thread.path) end
	local function resolved()
		route.busy = false
		route.resolved[thread.id] = true
		cx:toast("success", "Resolved the thread", thread.path)
	end
	if b.fixture then return resolved() end
	route.busy = true
	b.github.run(Github.commands.resolve(thread.id), function(_, err)
		if b.closed then return end
		if err then
			route.busy = false
			cx:toast("error", err.message, pr.key)
		else
			resolved()
		end
		draw(b, cx)
	end)
end
ACTIONS["fixes-rerun"] = function(b, cx)
	local route = b.s.route
	if route then ACTIONS["card-rerun"](b, cx, route.key) end
end
ACTIONS["fixes-log"] = function(b, cx)
	local _, pr, step = fixTarget(b)
	if pr == nil or step == nil or step.check == nil then return end
	local url = Fixes.logUrl(step.check, pr.repo)
	if url == "" then return cx:toast("error", "Couldn't open the log: GitHub gave no link for " .. step.check.name, pr.key) end
	cx:open(url)
end
-- G: the step on GitHub: the conflict editor, the thread, the check, the review, or the pull request.
ACTIONS["fixes-github"] = function(b, cx)
	local _, pr, step = fixTarget(b)
	if pr == nil then return end
	local url = pr.url
	if step then
		if step.group == "conflict" then url = pr.url .. "/conflicts"
		elseif step.thread then url = step.thread.url
		elseif step.review then url = step.review.url
		elseif step.check and step.check.url ~= "" then url = step.check.url end
	end
	cx:open(url)
end
-- ⏎ in the panel runs the highlighted action; the agent action is the card's own.
ACTIONS["fixes-press"] = function(b, cx)
	local act = State.fixPress(b.s)
	if act == nil then return end
	local route, pr = fixTarget(b)
	if act == "agent" then
		local main = State.fixMain(b.s)
		local handler = if main then ACTIONS[main.act] else nil
		if handler and pr then handler(b, cx, pr.key) end
		return
	end
	local handler = ACTIONS["fixes-" .. act]
	if handler and route then handler(b, cx, "") end
end

local function dispatch(b: Block, cx: BlockCx, action: Keys.Action)
	local handler = ACTIONS[action.act]
	if not handler then return end
	-- Ownership another window stored joins before the handler reads a guard, so no direct effect reaches a Tandem branch.
	if syncOwnership(b, cx) then draw(b, cx) end
	-- A draw that raised has closed the block: the handler sends nothing for it.
	if b.closed then return end
	handler(b, cx, action.value or "")
end

-- The agent the reader's omp is set to, and the models it can run (a live board only).
local function loadAgent(b: Block, cx: BlockCx)
	Host.timer(0, function()
		AgentHost.findAgent(function(agent)
			if b.closed or not agent then return end
			b.agent = agent
			b.s.agent = { models = {}, model = agent.model, effort = agent.effort }
			draw(b, cx)
			AgentHost.listModels(agent, function(models)
				if b.closed then return end
				local choice = b.s.agent
				if choice then
					for _, model in models do table.insert(choice.models, { selector = model.selector, name = model.name, efforts = model.efforts }) end
				end
				draw(b, cx)
			end)
		end)
	end)
end

-- Whether a click held `name` (shift, ctrl, alt or meta): Tern lists the held modifiers in `ev.mods`.
local function held(ev: UiEvent, name: string): boolean
	local mods: any = ev.mods
	if type(mods) ~= "table" then return false end
	return table.find(mods, name) ~= nil or mods[name] == true
end

local function actionOf(ev: UiEvent): Keys.Action?
	-- ⌘-click and ⇧-click on a card select it for Merge selected or Close stale instead of moving the selection.
	if ev.ev == "action" and ev.act == "hub-select" and (held(ev, "meta") or held(ev, "shift")) then
		return { act = "hub-mark", value = ev.value }
	end
	if ev.ev == "action" then return { act = ev.act, value = ev.value } end
	return nil
end

local block: BlockDef<Block> = {
	init = function(cx: BlockCx, args: { string }, saved: any): Block
		local opts, problem = options(args)
		local prs: { Model.HubPR } = {}
		local now = Host.time()
		local refreshedAt: string? = nil
		local fixture = if opts then opts.fixture else nil
		-- A sample board reads the recorded `tandem watch --json` with no process, and flags every list it shows.
		local watched: { [string]: boolean } = {}
		if fixture then watched = Model.parseTandemWatch(require("../../fixtures/hub/raw-tandem-watch")) or {} end
		local live = opts ~= nil and fixture == nil
		local cache: Sync.Cache? = nil
		if fixture then
			local data = FIXTURES[fixture]()
			prs, now, refreshedAt = flagged(watched, data.prs), data.asOf, data.asOfIso
		elseif live then
			-- Open from the cache with no network wait; the first tick refreshes in the background.
			cache = readCache()
			if cache then
				prs, refreshedAt = cache.prs, cache.refreshedAt
				-- Ownership the cache holds stands until a read of Tandem succeeds: a failed read or an earlier GitHub refresh keeps it.
				for _, pr in prs do
					if pr.tandem then watched[string.lower(pr.repo) .. "#" .. pr.number] = true end
				end
				writeStatus(cache)
			end
		end
		local s = State.new(prs, now, saved)
		if fixture then
			State.setRecent(s, SAMPLE_RECENT)
		else
			-- The picker's list moves to hub.recent the first time the hub loads.
			Fetch.migrateRecent()
			State.setRecent(s, Fetch.recentPrs())
		end
		s.refreshedAt = refreshedAt
		s.loading = live and cache == nil
		if problem then s.error = { operation = "hub", message = problem } end
		local b: Block = {
			s = s, cache = cache, fixture = fixture, generate = opts ~= nil and opts.generate, agent = nil, agentFlight = nil, botKeys = {},
			github = Github.client(Fetch.runner, Host.json.decode), timers = {},
			flights = { refresh = false, checks = false, probe = false, flake = false, tandem = false }, watched = watched, handoffs = 0, seen = {}, heard = {}, held = if cache then storedId(cache) else nil, replays = {}, retired = {}, unsaved = false, root = nil, rootWaiters = nil,
			sched = {
				probedAt = now, probeChanged = false, focusedAt = if live then now else nil, checksAt = nil,
				refreshTried = nil, lastModified = if cache then cache.lastModified else nil,
			},
			closed = false, refetch = false, show = nil, step = 0, records = {}, detecting = {}, flakeTried = {},
			histories = nil :: any,
		}
		b.histories = Github.historyCache(b.github)
		if fixture then
			-- The sample board's failing checks come with recorded evidence: one flaky, one a real type error.
			local evidence: any = require("../../fixtures/hub/flake")
			for key, name in evidence.board do
				local pr = State.prOf(s, key)
				for _, case in evidence.cases do
					if pr and case.name == name then
						local verdict = Model.flake(evidence.evidence(case))
						s.flakes[key] = { flaky = verdict.flaky, reason = verdict.reason, runs = evidence.runIds[key], headOid = pr.headOid }
					end
				end
			end
			-- A sample may bring how its repos merge and whether they allow auto-merge.
			local data: any = FIXTURES[fixture]()
			for repo, resolution in (data.merges or {}) do s.merges[repo] = resolution end
			for repo, allowed in (data.autoMerge or {}) do s.autoMerge[repo] = allowed end
			for key, agent in (data.agents or {}) do s.agents[key] = agent end
			if data.runningKey then
				b.agentFlight = { key = data.runningKey, settled = false, stopping = false, releasing = false, fixtureStep = data.runningStep }
			end
			State.project(s)
			local sample = table.clone(SAMPLE_AGENT)
			sample.models = table.clone(SAMPLE_AGENT.models)
			s.agent = sample
		elseif live then
			-- How each repo merges is known from the first frame, before any refresh.
			loadMerges(b)
			loadAgent(b, cx)
			loadTandem(b, cx)
			rearm(b, cx)
		end
		return b
	end,
	title = function(b: Block): string?
		return "Pull requests"
	end,
	view = function(b: Block): BlockView
		local s = b.s
		local motion = { born = s.born, next = {}, booted = s.booted, animate = not s.keyed }
		if s.route then
			local page = if s.route.kind == "review-fix" then ReviewFixPage.view(s, motion) else FixesPage.view(s, motion)
			s.born, s.booted = motion.next, true
			return { main = page, layer = nil }
		end
		local main = Board.view(s, motion)
		s.born, s.booted = motion.next, true
		return { main = main, layer = Board.layer(s) }
	end,
	event = function(b: Block, ev: UiEvent, cx: BlockCx)
		local action = actionOf(ev)
		if not action then return end
		b.s.keyed = false
		dispatch(b, cx, action)
	end,
	key = function(b: Block, key: Key, cx: BlockCx): boolean?
		local s = b.s
		local action = Keys.hubAction(s, key)
		if action then
			s.keyed = true
			dispatch(b, cx, action)
			return true
		end
		if s.mode == "reply" and s.route and s.route.reply then
			-- ⏎ is a new line in a reply; ⌘⏎ posts it (Keys.hubAction).
			local typed = if key.name == "enter" and not (key.meta or key.ctrl) then { name = "enter", shift = true } :: any else key
			Fields.key(s.route.reply, typed)
			return true
		end
		if s.mode == "search" then
			local next = Keys.hubAfterTyping(s.mode, Fields.key(s.search, key))
			if next then
				s.keyed = true
				dispatch(b, cx, next)
			end
			return true
		end
		if s.mode == "link" then
			Fields.key(s.link, key)
			return true
		end
		if s.mode == "menu" and s.methodEdit then
			Fields.key(s.methodEdit.field, key)
			return true
		end
		-- Menus and the key panel swallow the keys they don't use.
		return s.mode ~= "board"
	end,
	save = function(b: Block): any
		return State.saved(b.s)
	end,
}

return block
