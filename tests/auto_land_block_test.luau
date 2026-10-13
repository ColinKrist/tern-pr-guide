--!strict
-- Auto-land in the hub block: ⇧L writes the record and shows the chip, a passing PR queues once, a dequeue recovers by a
-- rebase when behind and an empty commit when up to date, the cap stops it, a closed block sends nothing, Tandem refuses,
-- the sample board stays local, and Settings' keys save the cap and the label. GitHub is a recording client whose
-- callbacks the test settles by hand.
local AutoLandRun = require("../src/hub/auto-land-run")
local Block: any = require("../src/hub/block")
local Cases: any = require("../fixtures/hub/cases")
local Host: any = require("../src/host")
local State = require("../src/hub/state")
local Sync = require("../src/hub/sync")
local Ui: any = require("../src/view/ui")

type Call = { kind: string, argv: { string }?, ids: { string }?, done: (any, any) -> () }

local NOW: number = Cases.asOf
local KEY = "acme/api#109"

-- A Github client that records every call and answers only when the test settles it.
local function recorder(): (any, { Call })
	local calls: { Call } = {}
	local client = {
		run = function(command: any, done: any) table.insert(calls, { kind = "run", argv = command.argv, done = done }) end,
		details = function(_pr: any, done: any) table.insert(calls, { kind = "details", done = done }) end,
		landFacts = function(ids: { string }, done: any) table.insert(calls, { kind = "landFacts", ids = ids, done = done }) end,
	}
	return client, calls
end

local function argv(call: Call): string
	return table.concat(call.argv or {}, " ")
end

local function facts(head: string, labels: { string }, events: { any }?): any
	return {
		byId = { ["PR_" .. KEY] = {
			id = "PR_" .. KEY, state = "open", draft = false, headOid = head, headAuthor = "jubbydev",
			labels = labels, events = events or {}, autoMerge = false,
		} },
		rateLimit = { cost = 1, remaining = 4000, limit = 5000, resetAt = "" },
	}
end

local function details(head: string, behindBy: number): any
	return {
		key = KEY, headOid = head, fetchedAt = "", reviews = {}, threads = {}, checks = {}, changedPaths = {},
		behindBy = behindBy, branch = { repo = "acme/api", name = "case-109" },
	}
end

return function()
	local fieldEnv: any = getfenv(Ui.field)
	local hostField = fieldEnv.tern
	local kv: { [string]: any } = {}
	local timers: { number } = {}
	local stub: { [string]: any } = {
		time = function(): number return NOW end,
		timer = function(ms: number, _fn: () -> ()): any
			table.insert(timers, ms)
			return { cancel = function() end }
		end,
		json = { decode = function(): any return nil end, encode = function(): string return "" end },
		getenv = function(): string? return nil end,
		kv = { get = function(key: string): any return kv[key] end, set = function(key: string, value: any) kv[key] = value end },
		plugin = { data = "/data" },
		fs = { exists = function(): boolean return false end, list = function(): { string } return {} end, read = function(): string return "" end },
	}
	local hostFields: { [string]: any } = {}
	for name, value in stub do
		hostFields[name] = Host[name]
		Host[name] = value
	end
	fieldEnv.tern = { ui = { node = function(kind: string, props: any): any return { k = kind, p = props } end } }

	local ok, err = pcall(function()
		local toasts: { { string } } = {}
		local cx: any = { cwd = "/reader" }
		function cx:render() end
		function cx:open() end
		function cx:frame() end
		function cx:toast(kind: string, text: string, sub: string?)
			table.insert(toasts, { kind, text, sub or "" })
		end
		local function lastToast(): { string } return toasts[#toasts] or { "", "", "" } end
		local function press(b: any, name: string, shift: boolean?, text: string?)
			Block.key(b, { name = name, text = text, shift = shift or false, meta = false, ctrl = false, alt = false } :: any, cx)
		end
		local function card(b: any): State.Card return State.card(b.s, KEY) :: State.Card end
		local function record(): any
			local stored = kv["hub.autoland"]
			return stored and stored.prs[KEY]
		end
		local function setPr(b: any, patch: { [string]: any })
			local prs = table.clone(b.s.prs)
			for i, pr in prs do
				if pr.key == KEY then
					local copy = table.clone(pr)
					for k, v in patch do copy[k] = v end
					prs[i] = copy
				end
			end
			b.s.prs = prs
			State.project(b.s)
		end

		-- A live board over the sample's PRs: the sample's own auto-land is cleared, and acme/api merges by its label.
		local b: any = Block.init(cx, { "fixture=cases" }, nil)
		b.fixture = nil
		State.stampLanding(b.s, {})
		b.cache = Sync.merge({ prs = b.s.prs, viewer = "jubbydev", rateLimit = { cost = 1, remaining = 1, limit = 1, resetAt = "" }, calls = {}, truncated = false } :: any,
			nil, { added = {}, tandem = {}, landing = {} }, NOW)
		local client, calls = recorder()
		b.github = client

		-- ⇧L turns it on: the record is written, the chip shows, and the first step reads the facts.
		State.select(b.s, KEY)
		assert(card(b).column == "ready")
		press(b, "l", true)
		local r = record()
		assert(r and r.phase == "waiting" and r.tries == 0 and r.head == "head109", "the record is written")
		assert(card(b).chips[1].text == "Auto-land" and card(b).chips[1].kind == "agent", "the chip shows")
		assert(toasts[#toasts][1] == "success" and toasts[#toasts][2] == "Auto-land on for #109")
		assert(#calls == 1 and calls[1].kind == "landFacts" and (calls[1].ids :: { string })[1] == "PR_" .. KEY)

		-- Checks pass and it is approved: the merge label goes on, once.
		calls[1].done(facts("head109", {}), nil)
		assert(#calls == 2 and argv(calls[2]) == "gh pr edit 109 --repo acme/api --add-label merge-queue", argv(calls[2]))
		assert(b.s.busy[KEY] == "Adding label…" and record().phase == "queued")
		-- Even with the stored record back at waiting (another window's write), a busy card is not stepped.
		local queuedRecord = record()
		local waiting = table.clone(queuedRecord)
		waiting.phase = "waiting"
		kv["hub.autoland"].prs[KEY] = waiting
		AutoLandRun.run(b, cx, false, function() end)
		assert(#calls == 2, "a run while the card is busy sends nothing")
		kv["hub.autoland"].prs[KEY] = queuedRecord
		calls[2].done("", nil)
		assert(b.s.busy[KEY] == nil and card(b).note == "Labeled merge-queue · waiting for the merge")
		assert(lastToast()[2] == "Added the merge-queue label to #109" and timers[#timers] == 3000, "it toasts and refreshes soon")

		-- Dequeued by the bot's blocked label: behind main, so it rebases. One try.
		local blocked = { { added = true, label = "blocked", actor = "aviator-app", bot = true, at = "2026-10-09T12:01:00Z" } }
		AutoLandRun.run(b, cx, true, function() end)
		assert(#calls == 3 and calls[3].kind == "landFacts")
		calls[3].done(facts("head109", { "blocked" }, blocked), nil)
		assert(#calls == 4 and calls[4].kind == "details" and record().tries == 1 and record().phase == "recovering")
		assert(card(b).chips[1].text == "Auto-land · try 1 of 5")
		calls[4].done(details("head109", 2), nil)
		assert(#calls == 5 and argv(calls[5]) == "gh pr update-branch 109 --repo acme/api --rebase", argv(calls[5]))
		assert(b.s.busy[KEY] == "Rebasing…")
		calls[5].done("", nil)
		assert(record().adopt == true and lastToast()[2] == "Rebased #109 on main" and b.s.busy[KEY] == nil)

		-- The rebase's head is adopted; the dequeue label comes off before the merge label goes back on.
		setPr(b, { headOid = "rebased", checks = { state = "passing", passing = 1, failing = 0, pending = 0 } })
		AutoLandRun.run(b, cx, true, function() end)
		calls[6].done(facts("rebased", { "blocked" }, blocked), nil)
		assert(#calls == 7 and argv(calls[7]) == "gh pr edit 109 --repo acme/api --remove-label blocked", argv(calls[7]))
		assert(record().head == "rebased" and record().phase == "queued")
		calls[7].done("", nil)
		assert(#calls == 8 and argv(calls[8]) == "gh pr edit 109 --repo acme/api --add-label merge-queue")
		calls[8].done("", nil)

		-- Dequeued again, now up to date: an empty commit through the three calls. Two tries.
		local again = { { added = true, label = "blocked", actor = "aviator-app", bot = true, at = "2026-10-09T12:02:00Z" } }
		AutoLandRun.run(b, cx, true, function() end)
		calls[9].done(facts("rebased", { "blocked" }, again), nil)
		calls[10].done(details("rebased", 0), nil)
		assert(argv(calls[11]) == "gh api repos/acme/api/git/commits/rebased --jq .tree.sha", argv(calls[11]))
		assert(b.s.busy[KEY] == "Pushing…")
		calls[11].done("tree1\n", nil)
		assert(argv(calls[12]) == "gh api repos/acme/api/git/commits -X POST -f message=Empty commit to re-run checks -f tree=tree1 -f parents[]=rebased --jq .sha")
		calls[12].done("sha1\n", nil)
		assert(argv(calls[13]) == "gh api repos/acme/api/git/refs/heads/case-109 -X PATCH -f sha=sha1 -F force=false")
		calls[13].done("", nil)
		assert(record().tries == 2 and record().head == "sha1" and record().phase == "waiting")
		assert(lastToast()[2] == "Pushed an empty commit to #109" and card(b).chips[1].text == "Auto-land · try 2 of 5")

		-- With the cap lowered to 2, the next failure stops it: Needs fixes, the reason, an error toast.
		press(b, "s", true)
		press(b, "-", false, "-")
		press(b, "-", false, "-")
		press(b, "-", false, "-")
		assert(kv["hub.autoland.settings"].tries == 2 and b.s.landSettings.tries == 2, "- lowers the cap and saves it")
		press(b, "escape")
		setPr(b, { headOid = "sha1", checks = { state = "failing", passing = 1, failing = 1, pending = 0 } })
		AutoLandRun.run(b, cx, true, function() end)
		local sent = #calls
		calls[sent].done(facts("sha1", {}), nil)
		assert(#calls == sent, "a stop sends nothing")
		assert(record().phase == "stopped" and record().reason == "Tried 2 times")
		assert(card(b).column == "needs_fixes" and card(b).chips[1].text == "Auto-land stopped" and card(b).detail == "Tried 2 times")
		assert(lastToast()[1] == "error" and lastToast()[2] == "Auto-land stopped on #109: tried 2 times" and lastToast()[3] == card(b).pr.title)

		-- ⇧L on the stopped card starts over; a closed block then sends nothing when the read answers.
		press(b, "l", true)
		assert(record().phase == "waiting" and record().tries == 0)
		sent = #calls
		assert(calls[sent].kind == "landFacts")
		b.closed = true
		calls[sent].done(facts("sha1", {}), nil)
		assert(#calls == sent and record().phase == "waiting", "a closed block sends nothing after a callback")
		b.closed = false

		-- Tandem's branches are refused.
		AutoLandRun.off(b, cx, KEY)
		assert(record() == nil and card(b).chips[1] ~= nil and card(b).chips[1].text ~= "Auto-land")
		setPr(b, { tandem = true, checks = { state = "passing", passing = 1, failing = 0, pending = 0 } })
		b.watched["acme/api#109"] = true
		local before = #calls
		Block.event(b, { ev = "action", act = "card-autoland", value = KEY } :: any, cx)
		assert(record() == nil and #calls == before, "Tandem refuses")
		assert(lastToast()[2] == "Couldn't turn on auto-land for #109: Tandem watches this pull request", lastToast()[2])

		-- Settings: + raises the cap, ⇧D edits the dequeue label, ⏎ saves it.
		press(b, "s", true)
		press(b, "=", true, "+")
		assert(kv["hub.autoland.settings"].tries == 3)
		press(b, "d", true)
		assert(b.s.landEdit and b.s.landEdit.text == "blocked")
		for _ = 1, 7 do press(b, "backspace") end
		for _, char in string.split("hold", "") do press(b, char, false, char) end
		press(b, "enter")
		assert(kv["hub.autoland.settings"].label == "hold" and b.s.landEdit == nil and b.s.menu == "settings", "⏎ saves the label and Settings stays")

		-- The sample board flips the chip in memory and touches neither kv nor GitHub.
		local sample: any = Block.init(cx, { "fixture=cases" }, nil)
		local sampleClient, sampleCalls = recorder()
		sample.github = sampleClient
		local stored = kv["hub.autoland"]
		State.select(sample.s, KEY)
		press(sample, "l", true)
		assert((State.card(sample.s, KEY) :: State.Card).chips[1].text == "Auto-land", "the sample's chip changes")
		assert(lastToast()[1] == "info" and lastToast()[2] == "The sample board doesn't auto-land" and lastToast()[3] == KEY)
		assert(kv["hub.autoland"] == stored and #sampleCalls == 0, "no kv write, no GitHub call")
		assert((State.card(sample.s, "acme/api#120") :: State.Card).chips[1].text == "Auto-land · try 2 of 3", "the sample's records show their marks")
		Block.event(sample, { ev = "action", act = "hub-refresh", value = "" } :: any, cx)
		assert(#sampleCalls == 0)
	end)
	for name in stub do Host[name] = hostFields[name] end
	fieldEnv.tern = hostField
	if not ok then error(err, 0) end
end
