--!strict
-- The hub's actions on a pull request that reach GitHub or the agent: merging (with the repo's method, a confirmed batch
-- one at a time, when ready) and cancelling a merge, re-requesting review, updating a branch, re-running failed checks,
-- adding and removing a PR by link, replying to and resolving a thread, summarizing feedback, and pushing or discarding
-- an agent's fix. Each keeps the shared cache in step through hub/store (`keepCache`). Block's ACTIONS table calls them.
local Agent = require("../agent")
local AgentHost = require("../agent-host")
local Details = require("./details")
local FilterStore = require("./filter-store")
local Fixes = require("./fixes")
local Github = require("../github")
local Lookups = require("./lookups")
local Model = require("./model")
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
local function mergeCard(b: Block, cx: BlockCx, key: string)
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
local function cancelMerge(b: Block, cx: BlockCx, key: string)
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
local function autoMerge(b: Block, cx: BlockCx, key: string)
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
local function rerequest(b: Block, cx: BlockCx, key: string)
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
local function confirm(b: Block, cx: BlockCx, _: string)
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

local function updateBranch(b: Block, cx: BlockCx, key: string)
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
	mergeCard = mergeCard,
	cancelMerge = cancelMerge,
	autoMerge = autoMerge,
	rerequest = rerequest,
	confirmCancel = confirmCancel,
	confirm = confirm,
	updateBranch = updateBranch,
	rerun = rerun,
	addByLink = addByLink,
	remove = remove,
	reviewEffect = reviewEffect,
	fixTarget = fixTarget,
	postReply = postReply,
	resolveThread = resolveThread,
}
