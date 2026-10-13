--!strict
-- Auto-land's rules: every step of the state machine, each merge kind's queue and signal, the recovery choice, the
-- chip text and the kv codecs.
local AutoLand = require("../src/hub/auto-land")
local Cases: any = require("../fixtures/hub/cases")
local Github = require("../src/github")
local Keys = require("../src/keys")
local State = require("../src/hub/state")
local Model = require("../src/hub/model")
local RawAutoLand: any = require("../fixtures/hub/raw-auto-land")

local NOW = 1791547200 -- 2026-10-09T12:00:00Z
local ISO = "2026-10-09T12:00:00Z"
local LATER = "2026-10-09T12:05:00Z"
local SETTINGS: AutoLand.Settings = { tries = 5, label = "blocked" }
local LABEL: Model.MergeMethod = { kind = "label", label = "merge-queue" }
local COMMENT: Model.MergeMethod = { kind = "comment", command = "/merge", cancel = nil }
local QUEUE: Model.MergeMethod = { kind = "queue" }

local function deep(value: any): any
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in value do out[k] = deep(v) end
	return out
end

-- acme/api#110: the viewer's, approved, checks passing, head "head110".
local function pr(patch: { [string]: any }?): Model.HubPR
	local out: any
	for _, case in Cases.prs do
		if case.key == "acme/api#110" then out = deep(case) end
	end
	for k, v in patch or {} do out[k] = v end
	return out
end

local function ctx(method: Model.MergeMethod?, at: number?, settings: AutoLand.Settings?): AutoLand.Context
	local now = at or NOW
	return { now = now, iso = if at then LATER else ISO, viewer = "jubbydev", method = method, settings = settings or SETTINGS }
end

local function record(patch: { [string]: any }?): AutoLand.Record
	local out: any = AutoLand.start(pr(), "2026-10-09T11:00:00Z")
	for k, v in patch or {} do out[k] = v end
	return out
end

local function facts(patch: { [string]: any }?): Model.LandFacts
	local out: any = {
		id = "PR_acme/api#110", state = "open", draft = false, headOid = "head110", headAuthor = "jubbydev",
		labels = {}, events = {}, autoMerge = false,
	}
	for k, v in patch or {} do out[k] = v end
	return out
end

local function event(added: boolean, label: string, at: string, bot: boolean?): Model.LabelEvent
	return { added = added, label = label, actor = if bot then "aviator-app" else "maria-k", bot = bot == true, at = at }
end

local function reviews(decision: string): any
	local out = deep(pr().reviews)
	out.decision = decision
	return out
end

local function testStart()
	local r = AutoLand.start(pr(), ISO)
	assert(r.key == "acme/api#110" and r.id == "PR_acme/api#110" and r.phase == "waiting" and r.tries == 0)
	assert(r.head == "head110" and r.adopt == false and r.queuedAt == nil and r.approved == false and r.at == ISO and r.rev == 1)
	local on = AutoLand.mark(r) :: any
	assert(on.state == "on" and on.tries == 0, "a record not stopped is an on mark with its tries")
	local stopped = AutoLand.mark(AutoLand.stop(r, "Merge conflict", ISO)) :: any
	assert(stopped.state == "stopped" and stopped.reason == "Merge conflict")
	assert(AutoLand.mark(nil) == nil)
end

local function testSupports()
	assert(AutoLand.supports({ method = LABEL, source = "user", ask = false }))
	assert(AutoLand.supports({ method = COMMENT, source = "declared", ask = false }))
	assert(AutoLand.supports({ method = QUEUE, source = "declared", ask = false }))
	assert(not AutoLand.supports({ method = { kind = "squash" }, source = "viewer", ask = false }), "GitHub's own methods are not offered")
	assert(not AutoLand.supports({ method = { kind = "rebase" }, source = "user", ask = false }))
	assert(not AutoLand.supports({ method = COMMENT, source = "learned", ask = true }), "a learned method nobody confirmed is not offered")
	assert(not AutoLand.supports(nil))
end

-- Rules 1 to 5: closed or merged, a stopped record, off the board, a draft, Tandem, the method.
local function testLeaving()
	local r = record()
	local next, effect = AutoLand.step(r, pr(), facts({ state = "merged" }), ctx(LABEL))
	assert(next == nil and effect and effect.kind == "off" and effect.notice == nil, "merged: off, quietly")
	next, effect = AutoLand.step(record({ phase = "stopped", reason = "x" }), nil, facts({ state = "closed" }), ctx(LABEL))
	assert(next == nil and effect and effect.kind == "off", "closed: off, even when stopped")

	local stopped = record({ phase = "stopped", reason = "Merge conflict" })
	next, effect = AutoLand.step(stopped, pr(), nil, ctx(LABEL))
	assert(next == stopped and effect == nil, "a stopped record stays while the head is the same")
	next, effect = AutoLand.step(stopped, pr({ headOid = "pushed" }), nil, ctx(LABEL))
	assert(next == nil and effect and effect.kind == "off" and effect.notice == nil, "the viewer's push after a stop turns it off quietly")

	next, effect = AutoLand.step(r, nil, nil, ctx(LABEL))
	assert(next == r and effect == nil, "a PR off the board is left alone")
	next, effect = AutoLand.step(r, pr({ draft = true }), nil, ctx(LABEL))
	assert(next == nil and effect and effect.kind == "off" and effect.notice == nil, "a draft drops it quietly")
	next, effect = AutoLand.step(r, pr({ tandem = true }), nil, ctx(LABEL))
	assert(next == nil and effect and effect.kind == "off" and effect.notice == "Tandem watches it")

	next, effect = AutoLand.step(r, pr(), nil, ctx({ kind = "squash" }))
	assert(next and next.phase == "stopped" and next.reason == "The merge method changed" and next.rev == 2)
	assert(effect and effect.kind == "stopped" and effect.reason == "The merge method changed")
	next = AutoLand.step(r, pr(), nil, ctx(nil))
	assert(next and next.reason == "The merge method changed", "no supported method stops it")
end

-- Rule 6: the head moved.
local function testHeadMoved()
	local moved = pr({ headOid = "new" })
	local next, effect = AutoLand.step(record({ phase = "recovering", adopt = true, tries = 1 }), moved, nil, ctx(QUEUE))
	assert(next and next.head == "new" and next.adopt == false and effect and effect.kind == "queue", "a rebase's new head is adopted, then it queues")
	assert(next.phase == "queued" and next.tries == 1)

	next, effect = AutoLand.step(record(), moved, nil, ctx(QUEUE))
	assert(next and next.head == "head110" and effect and effect.kind == "read", "without facts at the new head it reads")
	next, effect = AutoLand.step(record(), moved, facts({ headOid = "older" }), ctx(QUEUE))
	assert(effect and effect.kind == "read", "facts at another head don't count")

	next, effect = AutoLand.step(record({ phase = "queued", queuedAt = ISO }), moved, facts({ headOid = "new", headAuthor = "JubbyDev", autoMerge = true }), ctx(QUEUE))
	assert(next and next.head == "new" and next.queuedAt == ISO and next.phase == "queued", "the viewer's own push (any case) is accepted and it queues again")
	assert(effect and effect.kind == "queue")

	next, effect = AutoLand.step(record({ phase = "queued" }), pr({ headOid = "new", checks = { state = "pending", passing = 0, failing = 0, pending = 1 } }),
		facts({ headOid = "new" }), ctx(QUEUE))
	assert(next and next.phase == "waiting" and next.queuedAt == nil and effect == nil, "an accepted head waits on its checks")

	next, effect = AutoLand.step(record(), moved, facts({ headOid = "new", headAuthor = "maria-k" }), ctx(QUEUE))
	assert(next and next.reason == "New commits from @maria-k" and effect and effect.kind == "stopped")
	local unlinked: any = facts({ headOid = "new" })
	unlinked.headAuthor = nil
	next = AutoLand.step(record(), moved, unlinked, ctx(QUEUE))
	assert(next and next.reason == "New commits from someone else")
end

-- Rules 7 and 8: conflicts and reviews.
local function testConflictsAndReviews()
	local next, effect = AutoLand.step(record(), pr({ conflicts = true }), nil, ctx(QUEUE))
	assert(next and next.reason == "Merge conflict" and effect and effect.kind == "stopped")
	next = AutoLand.step(record(), pr({ reviews = reviews("changes_requested") }), nil, ctx(QUEUE))
	assert(next and next.reason == "Changes requested")
	next, effect = AutoLand.step(record({ approved = true }), pr({ reviews = reviews("review_required") }), nil, ctx(QUEUE))
	assert(next and next.reason == "Approval dismissed" and effect and effect.kind == "stopped")
	next, effect = AutoLand.step(record(), pr({ reviews = reviews("review_required") }), nil, ctx(QUEUE))
	assert(next and next.phase == "waiting" and next.approved == false and effect == nil, "never approved: it waits")
	next, effect = AutoLand.step(record(), pr({ checks = { state = "pending", passing = 1, failing = 0, pending = 1 } }), nil, ctx(QUEUE))
	assert(next and next.approved == true and next.rev == 2 and effect == nil, "an approval is remembered")
	next, effect = AutoLand.step(record(), pr({ reviews = reviews("none") }), nil, ctx(QUEUE))
	assert(next and next.phase == "queued" and next.approved == false and effect and effect.kind == "queue", "no review required: it queues")
	next = AutoLand.step(record({ phase = "queued", queuedAt = ISO }), pr({ reviews = reviews("none") }), facts({ autoMerge = true }), ctx(QUEUE))
	assert(next and next.phase == "queued", "and never stops on it")
end

-- Rule 9: a rebase in flight.
local function testRecovering()
	local r = record({ phase = "recovering", tries = 1, at = ISO, approved = true })
	local next, effect = AutoLand.step(r, pr(), nil, ctx(QUEUE, NOW + 599))
	assert(next == r and effect == nil, "unchanged until the head moves")
	next, effect = AutoLand.step(r, pr(), nil, ctx(QUEUE, NOW + 600))
	assert(next and next.phase == "waiting" and next.adopt == false and next.at == LATER and next.rev == 2 and effect == nil, "after 600 s the next step decides again")
end

-- Rule 10: waiting.
local function testWaiting()
	local failing = { state = "failing", passing = 3, failing = 1, pending = 0 }
	local next, effect = AutoLand.step(record(), pr({ checks = failing }), nil, ctx(QUEUE))
	assert(next and next.phase == "recovering" and next.tries == 1 and next.adopt == false and next.at == ISO and effect and effect.kind == "recover")
	next, effect = AutoLand.step(record({ tries = 5 }), pr({ checks = failing }), nil, ctx(QUEUE))
	assert(next and next.phase == "stopped" and next.reason == "Tried 5 times" and next.tries == 5 and effect and effect.kind == "stopped", "the cap stops it")
	next = AutoLand.step(record({ tries = 2 }), pr({ checks = failing }), nil, ctx(QUEUE, nil, { tries = 2, label = "blocked" }))
	assert(next and next.reason == "Tried 2 times", "the cap is the setting's")

	local r = record()
	next, effect = AutoLand.step(r, pr({ checks = { state = "pending", passing = 1, failing = 0, pending = 1 }, reviews = reviews("none") }), nil, ctx(QUEUE))
	assert(next == r and effect == nil, "pending checks: unchanged")
	next, effect = AutoLand.step(record(), pr({ checks = { state = "none", passing = 0, failing = 0, pending = 0 } }), nil, ctx(COMMENT))
	assert(next and next.phase == "queued" and next.queuedAt == ISO and effect and effect.kind == "queue", "no checks and approved: it queues")
	assert(#effect.ops == 1 and effect.ops[1].kind == "merge")

	next, effect = AutoLand.step(record(), pr(), nil, ctx(LABEL))
	assert(next and next.phase == "waiting" and effect and effect.kind == "read", "the label kind reads before it queues")
	next, effect = AutoLand.step(record(), pr(), facts(), ctx(LABEL))
	assert(next and next.phase == "queued" and effect and effect.kind == "queue" and #effect.ops == 1 and effect.ops[1].kind == "merge")
	next, effect = AutoLand.step(record(), pr(), facts({ labels = { "blocked", "bug" } }), ctx(LABEL))
	assert(effect and effect.kind == "queue" and #effect.ops == 2, "the dequeue label goes first")
	local remove: any = effect.ops[1]
	assert(remove.kind == "remove_label" and remove.label == "blocked" and effect.ops[2].kind == "merge")
end

-- Rule 11 and each kind's signal.
local function testSignals()
	local queued = record({ phase = "queued", queuedAt = "2026-10-09T11:30:00Z", approved = true })
	local function step(method: Model.MergeMethod, board: Model.HubPR, read: Model.LandFacts?, at: number?)
		return AutoLand.step(queued, board, read, ctx(method, at))
	end

	-- label
	local next, effect = step(LABEL, pr(), facts({ labels = { "merge-queue" } }))
	assert(next == queued and effect == nil, "the merge label on the PR: queued")
	next, effect = step(LABEL, pr(), nil)
	assert(next == queued and effect == nil, "no facts: queued")
	next, effect = step(LABEL, pr(), facts({ labels = { "blocked" }, events = { event(true, "blocked", "2026-10-09T11:40:00Z", true) } }))
	assert(next and next.phase == "recovering" and next.tries == 1 and effect and effect.kind == "recover", "the dequeue label added since: dequeued")
	next, effect = step(LABEL, pr(), facts({ labels = { "blocked" } }))
	assert(effect and effect.kind == "recover", "the dequeue label with no event to say when: dequeued")
	next, effect = step(LABEL, pr(), facts({ labels = { "blocked" }, events = { event(true, "blocked", "2026-10-09T11:00:00Z", true) } }))
	assert(next == queued and effect == nil, "a dequeue label from before the merge was asked for doesn't count")
	next, effect = step(LABEL, pr(), facts({ events = { event(false, "merge-queue", "2026-10-09T11:45:00Z") } }))
	assert(next == nil and effect and effect.kind == "off" and effect.notice == "the merge-queue label was removed", "a person removed the label: cancelled")
	next, effect = step(LABEL, pr(), facts({ events = { event(false, "merge-queue", "2026-10-09T11:00:00Z") } }))
	assert(next == queued and effect == nil, "a removal before the merge was asked for doesn't count")
	local botRemoved = facts({ events = { event(false, "merge-queue", "2026-10-09T11:55:00Z", true) } })
	next, effect = step(LABEL, pr(), botRemoved, NOW + 299)
	assert(next == queued and effect == nil, "a bot removed it: queued during the grace")
	next, effect = step(LABEL, pr(), botRemoved, NOW + 300)
	assert(effect and effect.kind == "recover", "a bot removed it 600 s ago with no dequeue label: dequeued")

	-- comment
	next, effect = step(COMMENT, pr(), nil)
	assert(next == queued and effect == nil)
	next, effect = step(COMMENT, pr({ mergeFailure = { kind = "bot", reason = "Blocked: checks failed" } }), nil)
	assert(effect and effect.kind == "recover", "a merge failure dequeues a comment merge")

	-- queue
	next, effect = step(QUEUE, pr(), facts({ autoMerge = true }))
	assert(next == queued and effect == nil)
	next, effect = step(QUEUE, pr(), nil)
	assert(next == queued and effect == nil, "no facts: queued")
	next, effect = step(QUEUE, pr({ mergeFailure = { kind = "queue", reason = "Removed from the merge queue" } }), facts())
	assert(effect and effect.kind == "recover", "a queue removal dequeues")
	next, effect = step(QUEUE, pr(), facts({ autoMerge = false }))
	assert(next == nil and effect and effect.kind == "off" and effect.notice == "auto-merge was turned off")
end

-- The label kind over the recorded auto-land read (the smoke repo, 2026-10-13): jubbydev added merge-queue at 09:28:48,
-- removed it at 09:28:53 and added blocked at 09:28:55.
local function testRecordedLabels()
	local parsed = Github.parseLandFacts(RawAutoLand) :: Github.LandFactsUpdate
	local recorded = parsed.byId["PR_kwDOVC46H88AAAABII2qXQ"]
	local head = recorded.headOid
	local board = pr({ headOid = head })
	local queued = record({ head = head, phase = "queued", queuedAt = "2026-10-13T09:28:48Z", approved = true })
	local at = Model.epoch("2026-10-13T09:30:00Z") :: number
	local function step(read: Model.LandFacts, now: number?)
		return AutoLand.step(queued, board, read, { now = now or at, iso = "2026-10-13T09:30:00Z", viewer = "jubbydev", method = LABEL, settings = SETTINGS })
	end

	local next, effect = step(recorded)
	assert(next and next.phase == "recovering" and effect and effect.kind == "recover", "blocked added after the merge was asked for: dequeued")

	local unblocked = table.clone(recorded)
	unblocked.labels = {}
	next, effect = step(unblocked)
	assert(next == nil and effect and effect.kind == "off" and effect.notice == "the merge-queue label was removed", "a person removed merge-queue: cancelled")

	local byBot = table.clone(unblocked)
	byBot.events = table.clone(recorded.events)
	byBot.events[2] = { added = false, label = "merge-queue", actor = "aviator-app", bot = true, at = "2026-10-13T09:28:53Z" }
	next, effect = step(byBot)
	assert(next == queued and effect == nil, "a bot removed it moments ago: still queued")
	next, effect = step(byBot, (Model.epoch("2026-10-13T09:28:53Z") :: number) + AutoLand.LABEL_GRACE)
	assert(effect and effect.kind == "recover", "a bot removed it with no dequeue label for 600 s: dequeued")
end

local function testKinds()
	assert(AutoLand.KINDS.label.needsFacts and not AutoLand.KINDS.comment.needsFacts and not AutoLand.KINDS.queue.needsFacts)
	assert(AutoLand.KINDS.label.queue(LABEL, nil, SETTINGS) == nil, "the label kind can't decide without facts")
	local ops = AutoLand.KINDS.queue.queue(QUEUE, nil, SETTINGS) :: { AutoLand.Op }
	assert(#ops == 1 and ops[1].kind == "merge")
	assert(AutoLand.KINDS.squash == nil and AutoLand.KINDS.merge == nil and AutoLand.KINDS.rebase == nil)
end

local function testRecovery()
	assert(AutoLand.recovery(3, false) == "rebase")
	assert(AutoLand.recovery(0, false) == "empty")
	assert(AutoLand.recovery(nil, false) == nil, "an unknown behind count has no safe recovery")
	assert(AutoLand.recovery(3, true) == nil and AutoLand.recovery(0, true) == nil, "nor does a conflict")
	local r = record({ phase = "recovering", tries = 1, rev = 4 })
	local rebased = AutoLand.recovered(r, "rebase", nil, LATER)
	assert(rebased.adopt == true and rebased.phase == "recovering" and rebased.head == "head110" and rebased.at == LATER and rebased.rev == 5)
	local pushed = AutoLand.recovered(r, "empty", "abc123", LATER)
	assert(pushed.head == "abc123" and pushed.phase == "waiting" and pushed.adopt == false and pushed.tries == 1 and pushed.rev == 5)
	assert(r.rev == 4 and r.adopt == false, "the record stepped from is left alone")
end

local function testLabel()
	assert(AutoLand.label({ state = "on", tries = 0 }, 5) == "Auto-land")
	assert(AutoLand.label({ state = "on", tries = 2 }, 5) == "Auto-land · try 2 of 5")
	assert(AutoLand.label({ state = "on", tries = 6 }, 5) == "Auto-land · try 6 of 6", "a cap lowered below the tries shows the tries")
	assert(AutoLand.label({ state = "stopped", reason = "x" }, 5) == "Auto-land stopped")
end

local function testCodecs()
	local r = record({ phase = "queued", queuedAt = ISO })
	local stopped = record({ key = "acme/mono#206", id = "PR_206", phase = "stopped", reason = "Merge conflict" })
	local saved = AutoLand.saveRecords({ [r.key] = r, [stopped.key] = stopped })
	assert(saved.schema == 1 and saved.prs[r.key] ~= r, "saved records are copies")
	local loaded = AutoLand.loadRecords(saved)
	assert(loaded["acme/api#110"].queuedAt == ISO and loaded["acme/api#110"].phase == "queued")
	assert(loaded["acme/mono#206"].reason == "Merge conflict")

	for _, raw in { nil :: any, "x", 5, {}, { schema = 2, prs = {} }, { schema = 1, prs = "x" } } do
		assert(next(AutoLand.loadRecords(raw)) == nil, "a malformed document is no records")
	end
	local function without(field: string, value: any): any
		local bad: any = table.clone(r)
		bad[field] = value
		return AutoLand.loadRecords({ schema = 1, prs = { [r.key] = bad, [stopped.key] = stopped } })
	end
	for _, case in { { "phase", "flying" }, { "tries", -1 }, { "tries", 1.5 }, { "head", 5 }, { "adopt", "yes" }, { "queuedAt", 3 }, { "rev", nil }, { "key", "other#1" } } do
		local kept = without(case[1], case[2])
		assert(kept["acme/api#110"] == nil and kept["acme/mono#206"] ~= nil, "a malformed record is left out: " .. case[1])
	end
	local noReason: any = table.clone(stopped)
	noReason.reason = nil
	assert(AutoLand.loadRecords({ schema = 1, prs = { [stopped.key] = noReason } })["acme/mono#206"] == nil, "a stopped record needs its reason")

	local defaults = AutoLand.loadSettings(nil)
	assert(defaults.tries == 5 and defaults.label == "blocked")
	local s = AutoLand.loadSettings({ tries = 50, label = "  do-not-merge " })
	assert(s.tries == 20 and s.label == "do-not-merge", "tries clamp to 20 and the label is trimmed")
	assert(AutoLand.loadSettings({ tries = 0 }).tries == 1 and AutoLand.loadSettings({ tries = 3.7 }).tries == 3)
	assert(AutoLand.loadSettings({ tries = "7", label = "   " }).tries == 5 and AutoLand.loadSettings({ label = "   " }).label == "blocked")
end

local function acts(list: { State.CardAction }): string
	local out = {}
	for _, item in list do table.insert(out, item.act) end
	return table.concat(out, ",")
end

local function find(list: { State.CardAction }, act: string): State.CardAction?
	for _, item in list do
		if item.act == act then return item end
	end
	return nil
end

-- The sample board's cards, the toggle's key, and Settings' keys and state.
local function testBoard()
	local s = State.new(Cases.prs, Cases.asOf, nil)
	for repo, resolution in Cases.merges do s.merges[repo] = resolution end
	State.stampLanding(s, Cases.landing)
	for _, case in Cases.prs do assert(case.autoLand == nil and case.pending == nil, "stamping leaves the fixture's PRs alone") end

	local trying = State.card(s, "acme/api#120") :: State.Card
	assert(trying.column == "in_review" and #trying.chips == 1, "an on mark is the card's one chip")
	assert(trying.chips[1].text == "Auto-land · try 2 of 5" and trying.chips[1].kind == "agent")
	local off = find(trying.more, "card-autoland") :: State.CardAction
	assert(off.label == "Turn off auto-land" and off.key == "⇧Q" and find(trying.more, "card-auto") == nil, "no Merge when ready while it is on")

	local queued = State.card(s, "acme/api#110") :: State.Card
	assert(queued.column == "ready" and queued.chips[1].text == "Auto-land" and queued.chips[1].kind == "agent")
	assert(queued.note == "Labeled merge-queue · waiting for the merge" and queued.main and queued.main.act == "card-cancel")

	local stopped = State.card(s, "acme/mono#206") :: State.Card
	assert(stopped.column == "needs_fixes" and stopped.chips[1].text == "Auto-land stopped" and stopped.chips[1].kind == "bad")
	assert(stopped.chips[2].text == "Resolve conflicts" and stopped.detail == "Merge conflict", "the reason is the detail")
	assert((find(stopped.more, "card-autoland") :: State.CardAction).label == "Turn on auto-land", "a stopped card offers it again")

	assert((find((State.card(s, "acme/api#109") :: State.Card).more, "card-autoland") :: State.CardAction).label == "Turn on auto-land", "a supported Ready card offers it")
	assert(find((State.card(s, "acme/web#104") :: State.Card).more, "card-autoland") == nil, "a repo with no supported method doesn't")
	State.setTab(s, "review")
	assert(find((State.card(s, "acme/api#308") :: State.Card).more, "card-autoland") == nil, "nor does a review request")
	State.setTab(s, "mine")

	-- With an on mark in Needs fixes (a conflict stays a reason), the chip follows the reasons.
	State.setAutoLand(s, "acme/api#105", { state = "on", tries = 1 })
	local conflicted = State.card(s, "acme/api#105") :: State.Card
	assert(conflicted.column == "needs_fixes" and conflicted.chips[1].text == "Resolve conflicts" and conflicted.chips[2].text == "Auto-land · try 1 of 5")
	State.setAutoLand(s, "acme/api#105", nil)
	assert(#(State.card(s, "acme/api#105") :: State.Card).chips == 1)

	-- ⇧Q reaches the selected card's toggle.
	local function key(name: string, shift: boolean?, text: string?): any
		return { name = name, text = text, shift = shift == true, meta = false, ctrl = false, alt = false }
	end
	State.select(s, "acme/api#120")
	local toggle = Keys.hubAction(s, key("q", true)) :: Keys.Action
	assert(toggle.act == "card-autoland" and toggle.value == "acme/api#120", "⇧Q toggles auto-land")
	assert((Keys.hubAction(s, key("l")) :: Keys.Action).act == "hub-move", "l moves right")
	State.select(s, "acme/web#104")
	assert(Keys.hubAction(s, key("q", true)) == nil, "⇧Q does nothing on a card without auto-land")
	s.search.text = "x"
	State.select(s, "acme/api#120")
	assert(Keys.hubAction(s, key("q", true)) == nil, "letters act only while search is empty")
	s.search.text = ""

	-- Settings: - and + change the cap, ⇧D edits the label; while it is edited, ⏎ saves, Esc cancels, the rest is typed.
	State.openMenu(s, "settings")
	assert((Keys.hubAction(s, key("-", false, "-")) :: Keys.Action).value == "-1")
	assert((Keys.hubAction(s, key("=", false, "=")) :: Keys.Action).value == "+1")
	assert((Keys.hubAction(s, key("=", true, "+")) :: Keys.Action).act == "hub-land-tries")
	assert((Keys.hubAction(s, key("d", true)) :: Keys.Action).act == "hub-land-label")
	State.setLandTries(s, "+1")
	assert(s.landSettings.tries == 6 and (State.card(s, "acme/api#120") :: State.Card).chips[1].text == "Auto-land · try 2 of 6", "the chip reads the cap")
	State.setLandTries(s, "-1")
	State.setLandTries(s, "-1")
	assert(s.landSettings.tries == 4)
	State.setLandTries(s, "40")
	assert(s.landSettings.tries == 20, "the cap stops at 20")
	State.setLandTries(s, "+1")
	assert(s.landSettings.tries == 20)
	State.setLandTries(s, "1")
	State.setLandTries(s, "-1")
	assert(s.landSettings.tries == 1, "and at 1")

	State.beginLandEdit(s)
	assert(s.landEdit and s.landEdit.text == "blocked", "the field starts with the current label")
	assert((Keys.hubAction(s, key("enter")) :: Keys.Action).act == "hub-land-label-save")
	assert((Keys.hubAction(s, key("escape")) :: Keys.Action).act == "hub-land-label-cancel")
	assert(Keys.hubAction(s, key("d", true)) == nil and Keys.hubAction(s, key("-", false, "-")) == nil, "other keys type")
	s.landEdit.text = "   "
	assert(not State.saveLandEdit(s) and s.landSettings.label == "blocked", "an empty label is refused")
	s.landEdit.text = "  do-not-merge "
	assert(State.saveLandEdit(s) and s.landSettings.label == "do-not-merge" and s.landEdit == nil)
	State.beginLandEdit(s)
	State.cancelLandEdit(s)
	assert(s.landEdit == nil and s.landSettings.label == "do-not-merge")
	State.beginLandEdit(s)
	State.closeMenu(s)
	assert(s.landEdit == nil, "closing Settings drops the edit")
end

return function()
	testBoard()
	testStart()
	testSupports()
	testLeaving()
	testHeadMoved()
	testConflictsAndReviews()
	testRecovering()
	testWaiting()
	testSignals()
	testRecordedLabels()
	testKinds()
	testRecovery()
	testLabel()
	testCodecs()
end
