--!strict
-- The hub's actions on a pull request that reach GitHub or the agent: the board's side of each pull request action
-- (PrActions holds their rules and commands; a confirmed batch merges or closes one at a time), pushing an empty commit,
-- re-running failed checks, adding and removing a PR by link, replying to and resolving a thread, summarizing feedback,
-- and pushing or discarding an agent's fix. Each keeps the shared cache in step through hub/store (`keepCache`).
-- Block's ACTIONS table calls them.
local Agent = require("../agent")
local AutoLandRun = require("./auto-land-run")
local AgentHost = require("../agent-host")
local Details = require("./details")
local Fetch = require("../fetch")
local FilterStore = require("./filter-store")
local Fixes = require("./fixes")
local Github = require("../github")
local Host = require("../host")
local Log = require("../ci/log")
local Lookups = require("./lookups")
local Model = require("./model")
local PrActions = require("../pr-actions")
local Refresh = require("./refresh")
local ReviewFix = require("./review-fix")
local Runtime = require("./runtime")
local State = require("./state")
local Store = require("./store")
local Summary = require("./summary")

type Block = Runtime.Block

local draw, reasonOf, isoNow, revealSelected = Runtime.draw, Runtime.reasonOf, Runtime.isoNow, Runtime.revealSelected
local UNCHECKED, TANDEM_OWNS, joinOwned, keepCache = Store.UNCHECKED, Store.TANDEM_OWNS, Store.joinOwned, Store.keepCache
local ownershipChecked, syncOwnership, readLocal, writeAdded = Store.ownershipChecked, Store.syncOwnership, Store.readLocal, Store.writeAdded
local detectRepo, recordOf, saveRecord, setUserMethod = Lookups.detectRepo, Lookups.recordOf, Lookups.saveRecord, Lookups.setUserMethod
local refetch, refetchSoon = Refresh.refetch, Refresh.refetchSoon
local readFeedback = Details.readFeedback

local function summarize(b: Block, cx: BlockCx, key: string)
	local s = b.s
	local pr = State.prOf(s, if key ~= "" then key else s.selected or "")
	if b.closed or not pr or s.busy[pr.key] or s.agents[pr.key] then return end
	if not b.fixture and not b.agent then return cx:toast("error", "Couldn't summarize feedback: no agent is available") end
	local signature = State.feedbackSignature(pr)
	local since = Host.time() - b.skew
	State.startTiming(s, pr.key, since, Fetch.expectedHubSeconds("summary"))
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
				elseif not b.fixture then
					Fetch.saveHubSeconds("summary", Host.time() - b.skew - since)
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
-- Pull request actions -------------------------------------------------------------------------------------
-- PrActions holds the rules and the commands; this is the board's side of each: the busy mark, the cache edit, the
-- toast, the refresh, and auto-land stepping aside for a merge by hand.

-- What a sample board says instead of sending each action.
local SAMPLE: { [string]: string } = {
	merge = "The sample board doesn't merge", ["auto-merge"] = "The sample board doesn't merge",
	["cancel-merge"] = "The sample board doesn't cancel merges", update = "The sample board doesn't update branches",
	rerequest = "The sample board doesn't ask for reviews", close = "The sample board doesn't close pull requests",
}

-- The rules' context for `pr` as an action is decided: ownership another window stored joins first, and the durable
-- watched set counts too, since a batch holds pull requests the board may have dropped since it began.
local function liveCtx(b: Block, pr: Model.HubPR): PrActions.Ctx
	local _, readable = joinOwned(b)
	local s = b.s
	local current = State.prOf(s, pr.key) or pr
	local card = State.card(s, pr.key)
	local ctx = State.prCtx(s, current, if card then card.column else nil)
	ctx.readable = readable
	ctx.tandem = current.tandem or b.watched[string.lower(pr.repo) .. "#" .. pr.number] == true
	return ctx
end

-- What the success toast says. Read before the action runs: its edit changes what the PR says.
local function successText(id: PrActions.Id, pr: Model.HubPR, ctx: PrActions.Ctx): string
	local n = "#" .. pr.number
	if id == "merge" then
		local method = PrActions.method(ctx)
		if method.kind == "comment" then return "Commented " .. method.command .. " on " .. n end
		if method.kind == "label" then return "Added the " .. method.label .. " label to " .. n end
		if method.kind == "queue" then return "Added " .. n .. " to the merge queue" end
		return "Merged " .. n
	elseif id == "auto-merge" then
		return n .. " will merge when ready"
	elseif id == "cancel-merge" then
		local pending = pr.pending
		local method: Model.MergeMethod = if pending and pending.method == "queue" then { kind = "queue" } else PrActions.method(ctx)
		if method.kind == "comment" then return "Commented " .. (method.cancel or "") .. " on " .. n end
		if method.kind == "label" then return "Removed the " .. method.label .. " label from " .. n end
		if ctx.column == "in_review" then return n .. " won't merge when ready" end
		return "Removed " .. n .. " from the merge queue"
	elseif id == "update" then
		return "Updated " .. n .. " with " .. pr.baseBranch
	elseif id == "rerequest" then
		local again = Model.awaitingReReview(pr)
		return "Asked " .. Model.reviewerList(if again then again.ask else {}) .. " to review " .. n .. " again"
	end
	return "Closed " .. n
end

-- The board's edit once the action went through, kept in the shared cache on the head it began on. Built before the
-- action runs, from what the PR said then.
local function editOf(b: Block, cx: BlockCx, id: PrActions.Id, pr: Model.HubPR, ctx: PrActions.Ctx): (head: string) -> ()
	local s, key = b.s, pr.key
	local function gone(head: string)
		keepCache(b, cx, function()
			s.acted[key] = true
			State.dropPr(s, key)
		end, key, head)
	end
	if id == "merge" or id == "auto-merge" then
		local method = PrActions.method(ctx)
		-- GitHub's merge happens now and the PR leaves the board; a queue, comment or label hands it to the repo's tool, so
		-- the card shows it pending until a refresh brings the result.
		if id == "merge" and PrActions.immediate(method) then return gone end
		local kind: "queue" | "comment" | "label" = if method.kind == "comment" or method.kind == "label" then method.kind else "queue"
		return function(head)
			-- One stamp for every application of the edit: a replay must not move it past a bot's later rejection.
			local at = isoNow()
			keepCache(b, cx, function() State.setPending(s, key, { method = kind, at = at }) end, key, head, kind == "queue")
		end
	elseif id == "cancel-merge" then
		return function(head)
			keepCache(b, cx, function() State.setPending(s, key, nil) end, key, head)
			-- Cancelling the merge takes it back from auto-land too, which would only ask again.
			if not b.closed and pr.autoLand then AutoLandRun.off(b, cx, key) end
		end
	elseif id == "update" then
		return function(head)
			keepCache(b, cx, function()
				s.acted[key] = true
				State.branchUpdated(s, key)
			end, key, head)
		end
	elseif id == "rerequest" then
		local again = Model.awaitingReReview(pr)
		local logins = if again then again.ask else {}
		return function(head) keepCache(b, cx, function() State.reRequested(s, key, logins) end, key, head) end
	end
	return gone
end

-- Runs action `id` on `pr` now: the refusal, the busy mark, the command, the edit and the toast. With `done`, the caller
-- owns the toast and the refresh (a batch): it hears nil when the action went through, or the reason it didn't.
local function execute(b: Block, cx: BlockCx, id: PrActions.Id, pr: Model.HubPR, done: ((err: string?) -> ())?)
	if b.closed then return end
	local s = b.s
	local def = PrActions.get(id)
	local ctx = liveCtx(b, pr)
	local function fail(reason: string)
		if done then return done(reason) end
		cx:toast("error", "Couldn't " .. def.what(pr) .. ": " .. reason, pr.repo)
	end
	local refused = def.refusal(pr, ctx)
	if refused then return fail(refused) end
	-- Merging by hand overrides auto-land: it steps aside rather than ask for the merge a second time.
	local current = State.prOf(s, pr.key)
	if id == "merge" and current and current.autoLand and current.autoLand.state == "on" then
		AutoLandRun.off(b, cx, pr.key)
		if b.closed then return end
		if not done then cx:toast("info", "Auto-land off for #" .. pr.number .. ": merging by hand", pr.title) end
	end
	local success = successText(id, pr, ctx)
	local apply = editOf(b, cx, id, pr, ctx)
	local mark = def.progress(pr, ctx)
	local head = pr.headOid
	State.setBusy(s, pr.key, mark)
	def.run(pr, ctx, b.github, function(err)
		if b.closed then return end
		if err then
			State.setBusy(s, pr.key, nil)
			fail(reasonOf(err))
			return draw(b, cx)
		end
		-- The edit applies only on the head the action began on, and it is what clears the busy mark there. An adopted cache
		-- that moved the head skips it, so this action's own mark clears here, and only if nothing newer replaced it.
		if s.busy[pr.key] == mark then State.setBusy(s, pr.key, nil) end
		apply(head)
		-- Adopting another window's cache may have drawn, and the draw closed the block: nothing goes on from here.
		if b.closed then return end
		if done then
			done(nil)
		else
			cx:toast("success", success, pr.title)
			refetchSoon(b, cx)
		end
		draw(b, cx)
	end)
end

-- A pull request action from a key, a click or the Pull request menu: offered actions only, the question first when it
-- asks one, else it runs. A refusal known now is said now, before any question.
local function act(b: Block, cx: BlockCx, id: PrActions.Id, key: string)
	local s = b.s
	local pr = State.prOf(s, if key ~= "" then key else s.selected or "")
	if not pr or s.busy[pr.key] then return end
	local card = State.card(s, pr.key)
	local ctx = State.prCtx(s, pr, if card then card.column else nil)
	local def = PrActions.get(id)
	if not def.offered(pr, ctx) then return end
	State.select(s, pr.key)
	if not b.fixture then
		if id == "merge" and ctx.merge == nil then
			-- Not known yet how this repo merges: GitHub's merge is never the guess.
			detectRepo(b, cx, pr.repo)
			return cx:toast("info", "Checking how " .. pr.repo .. " merges…", "Try again in a moment")
		end
		local refused = def.refusal(pr, liveCtx(b, pr))
		if refused then return cx:toast("error", "Couldn't " .. def.what(pr) .. ": " .. refused, pr.repo) end
	end
	if State.ask(s, pr.key, id) then return end
	if b.fixture then return cx:toast("info", SAMPLE[id], pr.key) end
	execute(b, cx, id, pr, nil)
end

local function refList(prs: { Model.HubPR }): string
	local out: { string } = {}
	for _, pr in prs do table.insert(out, "#" .. pr.number) end
	return table.concat(out, ", ")
end

-- Runs the confirmed selection one pull request at a time, in column order. A failure stops the rest, which stay
-- selected; one toast names what went through and what didn't.
local function runBatch(b: Block, cx: BlockCx, keys: { string }, id: "merge" | "close")
	local s = b.s
	if b.fixture then return cx:toast("info", SAMPLE[id]) end
	local queue: { Model.HubPR } = {}
	for _, key in keys do
		local card = State.card(s, key)
		if card and not s.busy[key] then table.insert(queue, card.pr) end
	end
	if #queue == 0 then return end
	local merge = id == "merge"
	local finished: { Model.HubPR } = {}
	local handed = false -- some went to a repo's tool (comment, label, queue) rather than merging at once
	local step: (index: number) -> ()
	local function finish(failed: Model.HubPR?, reason: string?)
		if b.closed then return end
		local rest: { Model.HubPR } = {}
		for i = #finished + 1, #queue do table.insert(rest, queue[i]) end
		local done = if merge then (if handed then "Asked to merge " else "Merged ") else "Closed "
		if failed and reason then
			local text = (if #finished > 0 then done .. refList(finished) .. ". " else "") .. "Couldn't " .. id .. " #" .. failed.number .. ": " .. reason
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
		local resolved = s.merges[pr.repo]
		if merge and resolved and not PrActions.immediate(resolved.method) then handed = true end
		execute(b, cx, id, pr, function(err: string?)
			-- A redraw while keeping the cache may have closed the block: no next command, no toast.
			if b.closed then return end
			if err then return finish(pr, err) end
			table.insert(finished, pr)
			s.marked[pr.key] = nil
			step(index + 1)
		end)
	end
	step(1)
end

-- Esc on the learned-method question declines it for good: the repo is not asked again.
local function confirmCancel(b: Block, cx: BlockCx, _: string)
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

-- ⌘⏎ on an inline question: the selection's batch, or the one pull request's merge or close.
local function confirm(b: Block, cx: BlockCx, _: string)
	local s = b.s
	local confirm = s.confirm
	if not confirm then return end
	State.cancelConfirm(s)
	if confirm.kind == "batch-merge" or confirm.kind == "batch-close" then
		return runBatch(b, cx, confirm.keys, if confirm.kind == "batch-merge" then "merge" else "close")
	end
	local card = State.card(s, confirm.keys[1])
	if not card then return end
	local id: PrActions.Id = if confirm.kind == "close" then "close" else "merge"
	-- Saying yes to the suggestion makes it the viewer's own setting.
	local resolved = s.merges[card.pr.repo]
	if confirm.kind == "learned" and resolved then setUserMethod(b, cx, card.pr.repo, resolved.method) end
	if b.fixture then return cx:toast("info", SAMPLE[id], card.pr.key) end
	execute(b, cx, id, card.pr, nil)
end

-- Push empty commit (U, after the inline question): a fixes page whose branch is up to date with its base gets a commit
-- that changes nothing, so every check runs again, for a check that can't be re-run on its own.
local PUSH_BUSY = "Pushing…"

local function pushEmpty(b: Block, cx: BlockCx, key: string)
	local s = b.s
	local pr = State.prOf(s, key)
	if pr == nil or s.busy[key] then return end
	if not ownershipChecked(b, cx, "push to #" .. pr.number) then return end
	if pr.tandem then return cx:toast("error", "Couldn't push an empty commit: " .. TANDEM_OWNS, pr.repo) end
	local action = State.branchAction(s, key)
	if action == nil or action.kind ~= "empty" then return cx:toast("info", "#" .. pr.number .. " isn't up to date with " .. pr.baseBranch, pr.key) end
	if b.fixture then return cx:toast("info", "The sample board doesn't push commits", pr.key) end
	local branch, head = action.branch, pr.headOid
	local function fail(err: Model.Error?)
		if b.closed then return end
		State.setBusy(s, key, nil)
		local message = if err then err.message else "no answer"
		local reason = if string.find(message, "fast forward", 1, true) then "the branch moved; refresh and try again" else reasonOf(message)
		cx:toast("error", "Couldn't push an empty commit: " .. reason, pr.repo)
		draw(b, cx)
	end
	State.setBusy(s, key, PUSH_BUSY)
	draw(b, cx)
	b.github.run(Github.commands.headTree(branch.repo, head), function(tree, err)
		if err or tree == nil then return fail(err) end
		b.github.run(Github.commands.emptyCommit(branch.repo, string.match(tree, "%S+") or "", head), function(sha, err2)
			if err2 or sha == nil then return fail(err2) end
			b.github.run(Github.commands.moveBranch(branch.repo, branch.name, string.match(sha, "%S+") or ""), function(_, err3)
				if err3 then return fail(err3) end
				if b.closed then return end
				if s.busy[key] == PUSH_BUSY then State.setBusy(s, key, nil) end
				keepCache(b, cx, function()
					s.acted[key] = true
					State.branchUpdated(s, key)
				end, key, head)
				if b.closed then return end
				cx:toast("success", "Pushed an empty commit to #" .. pr.number, pr.repo)
				refetchSoon(b, cx)
				draw(b, cx)
			end)
		end)
	end)
end

-- Re-run failed checks (⇧R, behind Fix checks ▾): the card's failing checks, read from the details, go to the CI
-- module that owns them, which re-runs each of its runs or builds once. Only a press runs it.
local function rerun(b: Block, cx: BlockCx, key: string)
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
	State.setBusy(s, key, "Reading checks…")
	draw(b, cx)
	b.github.details(pr, function(d, err)
		if b.closed then return end
		if d == nil then return fail(if err then err.message else "no answer") end
		local failing: { Log.Check } = {}
		for _, check in d.checks do table.insert(failing, check) end
		if #failing == 0 then return fail("GitHub lists no failing checks") end
		local groups, unowned = Log.byProvider(b.ci, failing)
		if #unowned > 0 then
			local more = if #unowned > 1 then " and " .. (#unowned - 1) .. " more" else ""
			cx:toast("error", "Couldn't re-run " .. unowned[1].name .. more .. ": no CI module reads " .. (if #unowned > 1 then "them" else "it"), pr.repo)
		end
		if #groups == 0 then
			State.setBusy(s, key, nil)
			return draw(b, cx)
		end
		State.setBusy(s, key, "Re-running…")
		draw(b, cx)
		Log.each(groups, function(group: Log.Group, after)
			local ok, thrown = pcall(group.provider.retry, group.checks, pr.repo, function(_, why) after(why) end)
			if not ok then after(tostring(thrown)) end
		end, function(_, why)
			if b.closed then return end
			if why then return fail(why) end
			State.setBusy(s, key, nil)
			b.flakeTried[pr.key .. "@" .. pr.headOid] = nil
			State.setFlake(s, key, nil)
			cx:toast("success", "Re-running failed checks on #" .. pr.number, pr.repo)
			refetchSoon(b, cx)
			draw(b, cx)
		end)
	end)
end

-- ⏎: add a new pull request to Review requests, add a folded one (Team requests, Inactive) to To review, or show
-- one the board already has.
local function addByLink(b: Block, cx: BlockCx, _: string)
	local s = b.s
	local target = State.linkTarget(s)
	if target.kind == "board" then
		State.closeLink(s, true)
		if State.show(s, target.pr.key) then
			FilterStore.save(b, cx)
			revealSelected(b, cx)
		end
	elseif target.kind == "folded" then
		local pr = target.pr
		if not b.fixture then
			local added, why = State.withAdded(readLocal().added, { repo = pr.repo, number = pr.number })
			local problem = why or (if added then writeAdded(added) else nil)
			if problem then return cx:toast("error", "Couldn't add #" .. pr.number .. ": " .. problem, pr.repo) end
		end
		State.closeLink(s, true)
		keepCache(b, cx, function() State.markAdded(s, pr.key) end, pr.key, pr.headOid)
		if b.closed then return end
		if State.show(s, pr.key) then
			FilterStore.save(b, cx)
			revealSelected(b, cx)
		end
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

-- Remove from Review requests (X): only on a pull request added by link.
local function remove(b: Block, cx: BlockCx, key: string)
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

local function reviewEffect(b: Block, cx: BlockCx, action: "push" | "discard")
	local page, request = State.reviewPage(b.s), State.reviewRequest(b.s)
	if not page or page.busy then return end
	local verb = if action == "push" then "push" else "discard"
	if not request then return cx:toast("error", "Couldn't " .. verb .. " the fix: wait for the fix to load") end
	if action == "push" and page.ask then return end
	-- A chat sync still reading the worktree may be about to change the fix.
	if action == "push" and b.chats[request.key] == Runtime.CHAT_SYNCING then return cx:toast("error", "Couldn't push the fix: the agent chat's changes are still being read") end
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
-- The page's pull request and the thread of the step on show, when it has one.
local function fixTarget(b: Block): (State.Route?, Model.HubPR?, Fixes.Step?)
	local s = b.s
	local route = s.route
	if route == nil then return nil, nil, nil end
	return route, State.prOf(s, route.key), State.fixStep(s)
end

local function postReply(b: Block, cx: BlockCx, _: string)
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
local function resolveThread(b: Block, cx: BlockCx, _: string)
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

return {
	summarize = summarize,
	act = act,
	confirmCancel = confirmCancel,
	confirm = confirm,
	pushEmpty = pushEmpty,
	rerun = rerun,
	addByLink = addByLink,
	remove = remove,
	reviewEffect = reviewEffect,
	fixTarget = fixTarget,
	postReply = postReply,
	resolveThread = resolveThread,
}
