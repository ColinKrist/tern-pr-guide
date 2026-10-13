--!strict
-- Runs auto-land on the hub's board while a hub block is open. It owns the records (kv `hub.autoland`) and the settings
-- (kv `hub.autoland.settings`), steps every record after a refresh and after a checks update (hub/auto-land decides), and
-- carries out what a step asks: queue the merge with the repo's method, rebase or push an empty commit, read the auto-land
-- facts, stop or turn off. ⇧L's ACTIONS entry calls `toggle`; Cancel merge calls `off`. A sample board never reaches GitHub.
local AutoLand = require("./auto-land")
local Github = require("../github")
local Host = require("../host")
local Lookups = require("./lookups")
local Model = require("./model")
local Runtime = require("./runtime")
local State = require("./state")
local Store = require("./store")

type Block = Runtime.Block
type Record = AutoLand.Record
type Refetch = (Block, BlockCx) -> ()

local draw, reasonOf, isoNow = Runtime.draw, Runtime.reasonOf, Runtime.isoNow
local TANDEM_OWNS, keepCache, ownershipChecked = Store.TANDEM_OWNS, Store.keepCache, Store.ownershipChecked

local KV_RECORDS, KV_SETTINGS = "hub.autoland", "hub.autoland.settings"
local QUEUE_BUSY: { [string]: string } = { comment = "Commenting…", label = "Adding label…", queue = "Queuing…" }
local CHECK_BUSY, REBASE_BUSY, PUSH_BUSY = "Checking the branch…", "Rebasing…", "Pushing…"

local M = {}

-- The stored records, and whether the store could be read.
local function readRecords(): ({ [string]: Record }, boolean)
	local ok, raw = pcall(Host.kv.get, KV_RECORDS)
	if not ok then return {}, false end
	return AutoLand.loadRecords(raw), true
end

local function writeRecords(records: { [string]: Record }): string?
	local ok, err = pcall(Host.kv.set, KV_RECORDS, AutoLand.saveRecords(records))
	return if ok then nil else tostring(err)
end

function M.settings(): AutoLand.Settings
	local ok, raw = pcall(Host.kv.get, KV_SETTINGS)
	return AutoLand.loadSettings(if ok then raw else nil)
end

function M.saveSettings(settings: AutoLand.Settings): string?
	local ok, err = pcall(Host.kv.set, KV_SETTINGS, { tries = settings.tries, label = settings.label })
	return if ok then nil else tostring(err)
end

-- The board's marks, by key, from the stored records.
function M.marks(): { [string]: Model.LandMark }
	local out: { [string]: Model.LandMark } = {}
	for key, record in readRecords() do out[key] = AutoLand.mark(record) :: Model.LandMark end
	return out
end

-- Replaces the record `from` with `to` (nil deletes it), only while the store still holds `from` at its revision, and says
-- whether the store holds the write afterwards. Read then write: two windows deciding in the same instant can still both
-- act. Every op auto-land sends is safe to repeat (a label added twice, a queue joined twice, a rebase of a rebased branch,
-- an empty commit that fails to fast-forward) except a merge comment, which a second window would post twice.
local function commit(from: Record, to: Record?): boolean
	local records, readable = readRecords()
	local stored = records[from.key]
	if not readable or stored == nil or stored.rev ~= from.rev then return false end
	records[from.key] = to
	if writeRecords(records) then return false end
	local after = readRecords()[from.key]
	if to == nil then return after == nil end
	return after ~= nil and after.rev == to.rev
end

local function number(key: string): string
	return string.match(key, "#(%d+)$") or key
end

local function lowerFirst(text: string): string
	return string.lower(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- Puts `record`'s mark on the card (none for nil), through the shared cache.
local function setMark(b: Block, cx: BlockCx, key: string, record: Record?)
	local pr = State.prOf(b.s, key)
	keepCache(b, cx, function() State.setAutoLand(b.s, key, AutoLand.mark(record)) end, key, if pr then pr.headOid else nil)
end

local function toastStopped(cx: BlockCx, key: string, reason: string, title: string?)
	cx:toast("error", "Auto-land stopped on #" .. number(key) .. ": " .. lowerFirst(reason), title)
end

-- Stops auto-land on `key` for `reason`, from whatever record the store holds now.
local function stopNow(b: Block, cx: BlockCx, key: string, reason: string)
	if b.closed then return end
	State.setBusy(b.s, key, nil)
	local current = readRecords()[key]
	if current == nil or current.phase == "stopped" then return draw(b, cx) end
	local stopped = AutoLand.stop(current, reason, isoNow())
	if not commit(current, stopped) then return draw(b, cx) end
	setMark(b, cx, key, stopped)
	if b.closed then return end
	local pr = State.prOf(b.s, key)
	toastStopped(cx, key, reason, if pr then pr.title else nil)
	draw(b, cx)
end

local function queueFailure(op: AutoLand.Op, method: Model.MergeMethod): string
	if op.kind == "remove_label" then return "Couldn't remove the " .. op.label .. " label: " end
	if method.kind == "label" then return "Couldn't add the " .. method.label .. " label: " end
	if method.kind == "comment" then return "Couldn't comment " .. method.command .. ": " end
	return "Couldn't add it to the merge queue: "
end

local function toastQueued(cx: BlockCx, pr: Model.HubPR, method: Model.MergeMethod)
	if method.kind == "comment" then
		cx:toast("success", "Commented " .. method.command .. " on #" .. pr.number, pr.title)
	elseif method.kind == "label" then
		cx:toast("success", "Added the " .. method.label .. " label to #" .. pr.number, pr.title)
	else
		cx:toast("success", "Added #" .. pr.number .. " to the merge queue", pr.title)
	end
end

-- The guard before any write to GitHub: ownership joins and Tandem's branches are refused. Returns the board PR to act on.
local function writable(b: Block, cx: BlockCx, key: string): Model.HubPR?
	local pr = State.prOf(b.s, key)
	if pr == nil or not ownershipChecked(b, cx, "auto-land #" .. pr.number) then return nil end
	pr = State.prOf(b.s, key)
	if pr == nil or pr.tandem then return nil end
	return pr
end

-- Sends the queue's ops in order with the repo's method, then shows the merge pending like Merge does.
local function runQueue(b: Block, cx: BlockCx, record: Record, ops: { AutoLand.Op }, refetchSoon: Refetch)
	local s, key = b.s, record.key
	local pr = writable(b, cx, key)
	local resolution = if pr then s.merges[pr.repo] else nil
	if pr == nil or resolution == nil or pr.headOid ~= record.head then
		-- The step already stored "queued": nothing went out, so the record waits again or no signal would ever come.
		local back = table.clone(record)
		back.phase, back.queuedAt, back.rev = "waiting", nil, record.rev + 1
		if commit(record, back) then setMark(b, cx, key, back) end
		return
	end
	local method = resolution.method
	local head = pr.headOid
	State.setBusy(s, key, QUEUE_BUSY[method.kind] or "Queuing…")
	draw(b, cx)
	local function send(i: number)
		if b.closed then return end
		local op = ops[i]
		if op == nil then
			State.setBusy(s, key, nil)
			local kind: "queue" | "comment" | "label" = if method.kind == "comment" or method.kind == "label" then method.kind else "queue"
			local at = record.queuedAt or isoNow()
			keepCache(b, cx, function() State.setPending(s, key, { method = kind, at = at }, true) end, key, head, kind == "queue")
			if b.closed then return end
			toastQueued(cx, pr :: Model.HubPR, method)
			refetchSoon(b, cx)
			return draw(b, cx)
		end
		local command = if op.kind == "merge" then Github.commands.merge(pr :: Model.HubPR, method) else Github.commands.removeLabel(pr :: Model.HubPR, op.label)
		b.github.run(command, function(_, err)
			if b.closed then return end
			if err then return stopNow(b, cx, key, queueFailure(op, method) .. reasonOf(err.message)) end
			send(i + 1)
		end)
	end
	send(1)
end

-- After a recovery went through: the record learns it, and the card waits on its checks.
local function recovered(b: Block, cx: BlockCx, record: Record, how: "rebase" | "empty", sha: string?, head: string, refetchSoon: Refetch)
	if b.closed then return end
	local s, key = b.s, record.key
	local current = readRecords()[key]
	local done = if current and current.rev == record.rev then AutoLand.recovered(current, how, sha, isoNow()) else nil
	if not (current and done and commit(current, done)) then
		State.setBusy(s, key, nil)
		return draw(b, cx)
	end
	if s.busy[key] == REBASE_BUSY or s.busy[key] == PUSH_BUSY then State.setBusy(s, key, nil) end
	keepCache(b, cx, function()
		s.acted[key] = true
		State.branchUpdated(s, key)
		State.setAutoLand(s, key, AutoLand.mark(done))
	end, key, head)
	if b.closed then return end
	local pr = State.prOf(s, key)
	local title = if pr then pr.title else nil
	if how == "rebase" then
		cx:toast("success", "Rebased #" .. number(key) .. " on " .. (if pr then pr.baseBranch else "its base"), title)
	else
		cx:toast("success", "Pushed an empty commit to #" .. number(key), title)
	end
	refetchSoon(b, cx)
	draw(b, cx)
end

-- Makes the checks run again: reads how far the branch is behind its base, then rebases it there or pushes an empty commit.
-- A head that moved since the board read it does nothing this round.
local function runRecover(b: Block, cx: BlockCx, record: Record, refetchSoon: Refetch)
	local s, key = b.s, record.key
	local pr = writable(b, cx, key)
	if pr == nil then return end
	local board = pr :: Model.HubPR
	State.setBusy(s, key, CHECK_BUSY)
	draw(b, cx)
	b.github.details(board, function(details, err)
		if b.closed then return end
		local now = State.prOf(s, key)
		if details == nil then return stopNow(b, cx, key, "Couldn't read #" .. board.number .. ": " .. reasonOf(if err then err.message else "no answer")) end
		if now == nil or details.headOid ~= now.headOid then
			State.setBusy(s, key, nil)
			return draw(b, cx)
		end
		local head = now.headOid
		if now.conflicts then return stopNow(b, cx, key, "Merge conflict") end
		local how = AutoLand.recovery(details.behindBy, now.conflicts)
		if how == nil then return stopNow(b, cx, key, "Couldn't tell how far #" .. now.number .. " is behind " .. now.baseBranch) end
		if how == "rebase" then
			State.setBusy(s, key, REBASE_BUSY)
			draw(b, cx)
			return b.github.run(Github.commands.updateBranch(now, true), function(_, runErr)
				if b.closed then return end
				if runErr then return stopNow(b, cx, key, "Couldn't rebase: " .. reasonOf(runErr.message)) end
				recovered(b, cx, record, "rebase", nil, head, refetchSoon)
			end)
		end
		local branch = details.branch
		if branch == nil then return stopNow(b, cx, key, "Couldn't push an empty commit: the branch's repository is gone") end
		local function fail(runErr: Model.Error?)
			if b.closed then return end
			local message = if runErr then runErr.message else "no answer"
			local reason = if string.find(message, "fast forward", 1, true) then "the branch moved" else reasonOf(message)
			stopNow(b, cx, key, "Couldn't push an empty commit: " .. reason)
		end
		State.setBusy(s, key, PUSH_BUSY)
		draw(b, cx)
		b.github.run(Github.commands.headTree(branch.repo, head), function(tree, err1)
			if err1 or tree == nil then return fail(err1) end
			b.github.run(Github.commands.emptyCommit(branch.repo, string.match(tree, "%S+") or "", head), function(sha, err2)
				if err2 or sha == nil then return fail(err2) end
				local commitSha = string.match(sha, "%S+") or ""
				b.github.run(Github.commands.moveBranch(branch.repo, branch.name, commitSha), function(_, err3)
					if err3 then return fail(err3) end
					recovered(b, cx, record, "empty", commitSha, head, refetchSoon)
				end)
			end)
		end)
	end)
end

-- Steps one record and carries out what the step asks. Returns true when the step needs the auto-land read first.
local function stepOne(b: Block, cx: BlockCx, record: Record, facts: Model.LandFacts?, refetchSoon: Refetch): boolean
	local s, key = b.s, record.key
	if b.closed or s.busy[key] then return false end
	local pr = State.prOf(s, key)
	local resolution = if pr then s.merges[pr.repo] else nil
	-- The repo's merge setting isn't read yet: nothing is decided on a guess.
	if pr and resolution == nil then return false end
	local ctx: AutoLand.Context = {
		now = Host.time(), iso = isoNow(), viewer = if b.cache then b.cache.viewer else "",
		method = if AutoLand.supports(resolution) then (resolution :: Model.MergeResolution).method else nil, settings = s.landSettings,
	}
	local next, effect = AutoLand.step(record, pr, facts, ctx)
	if effect and effect.kind == "read" then return true end
	if next == record and effect == nil then return false end
	if not commit(record, next) then return false end
	setMark(b, cx, key, next)
	if b.closed or effect == nil then return false end
	local title = if pr then pr.title else nil
	if effect.kind == "stopped" then
		toastStopped(cx, key, effect.reason, title)
	elseif effect.kind == "off" then
		if effect.notice then cx:toast("info", "Auto-land off for #" .. number(key) .. ": " .. effect.notice, title) end
	elseif effect.kind == "queue" and next then
		runQueue(b, cx, next, effect.ops, refetchSoon)
	elseif effect.kind == "recover" and next then
		runRecover(b, cx, next, refetchSoon)
	end
	return false
end

-- Steps every record. With `read`, after every refresh, one auto-land read covers every record first (while any is not
-- stopped; the read costs the same for any number, and it is what drops a stopped record whose PR closed); without, after a
-- checks update, the steps that need the read get one read between them, at most once per run.
function M.run(b: Block, cx: BlockCx, read: boolean, refetchSoon: Refetch)
	if b.fixture or b.closed or b.flights.land then return end
	local records = readRecords()
	local function stepWith(list: { Record }, byId: { [string]: Model.LandFacts }?, again: boolean)
		local wanting: { Record } = {}
		for _, record in list do
			if stepOne(b, cx, record, if byId then byId[record.id] else nil, refetchSoon) and again then table.insert(wanting, record) end
		end
		return wanting
	end
	local function readFor(list: { Record })
		local ids: { string } = {}
		for _, record in list do table.insert(ids, record.id) end
		b.flights.land = true
		b.github.landFacts(ids, function(update)
			b.flights.land = false
			if b.closed then return end
			-- A failed read decides nothing that needed it; the next refresh reads again.
			local fresh = readRecords()
			local now: { Record } = {}
			for _, record in list do
				local current = fresh[record.key]
				if current then table.insert(now, current) end
			end
			stepWith(now, if update then update.byId else {}, false)
			draw(b, cx)
		end)
	end
	local list: { Record } = {}
	for _, record in records do table.insert(list, record) end
	table.sort(list, function(x: Record, y: Record): boolean return x.key < y.key end)
	if read then
		local live: { Record } = {}
		for _, record in list do
			if record.phase ~= "stopped" then table.insert(live, record) end
		end
		if #live > 0 then return readFor(list) end
		stepWith(list, nil, false)
		return
	end
	local wanting = stepWith(list, nil, true)
	if #wanting > 0 then
		local fresh = readRecords()
		local current: { Record } = {}
		for _, record in wanting do
			if fresh[record.key] then table.insert(current, fresh[record.key]) end
		end
		if #current > 0 then readFor(current) end
	end
end

local KIND_NAMES = "a merge queue, a merge comment or a merge label"

-- ⇧L on a card: turns auto-land on (a fresh record, so a stopped one starts over) or off.
function M.toggle(b: Block, cx: BlockCx, key: string, refetchSoon: Refetch)
	local s = b.s
	local card = State.card(s, key)
	if card == nil or s.busy[key] then return end
	local pr = card.pr
	State.select(s, key)
	local turnOff = pr.autoLand ~= nil and pr.autoLand.state == "on"
	if turnOff then
		if b.fixture then
			b.sampleLanding[key] = nil
			State.setAutoLand(s, key, nil)
			return cx:toast("info", "The sample board doesn't auto-land", pr.key)
		end
		M.off(b, cx, key)
		return cx:toast("info", "Auto-land off for #" .. pr.number, pr.title)
	end
	if pr.role ~= "mine" or pr.draft or card.column == "inactive" then return end
	local what = "turn on auto-land for #" .. pr.number
	if not ownershipChecked(b, cx, what) then return end
	local after = State.prOf(s, key)
	if pr.tandem or (after and after.tandem) then return cx:toast("error", "Couldn't " .. what .. ": " .. TANDEM_OWNS, pr.repo) end
	local resolution = s.merges[pr.repo]
	if resolution == nil and not b.fixture then
		Lookups.detectRepo(b, cx, pr.repo)
		return cx:toast("info", "Checking how " .. pr.repo .. " merges…", "Try again in a moment")
	end
	if not AutoLand.supports(resolution) then
		local why = if resolution and resolution.ask then pr.repo .. "'s merge method is only a suggestion" elseif resolution then pr.repo .. " merges with " .. Model.methodLine(resolution.method) else pr.repo .. " has no merge setting"
		return cx:toast("error", "Couldn't " .. what .. ": " .. why, "Auto-land works with " .. KIND_NAMES)
	end
	local fresh = AutoLand.start(pr, isoNow())
	if b.fixture then
		b.sampleLanding[key] = fresh
		State.setAutoLand(s, key, AutoLand.mark(fresh))
		return cx:toast("info", "The sample board doesn't auto-land", pr.key)
	end
	local records, readable = readRecords()
	if not readable then return cx:toast("error", "Couldn't " .. what .. ": the auto-land store couldn't be read", pr.repo) end
	local old = records[key]
	if old then fresh.rev = old.rev + 1 end
	records[key] = fresh
	local why = writeRecords(records)
	if why then return cx:toast("error", "Couldn't " .. what .. ": " .. why, pr.repo) end
	setMark(b, cx, key, fresh)
	if b.closed then return end
	cx:toast("success", "Auto-land on for #" .. pr.number, pr.title)
	M.run(b, cx, true, refetchSoon)
end

-- Turns auto-land off for `key` without a toast (Cancel merge, and ⇧L's off).
function M.off(b: Block, cx: BlockCx, key: string)
	if b.fixture then return end
	local records, readable = readRecords()
	if readable and records[key] then
		records[key] = nil
		writeRecords(records)
	end
	setMark(b, cx, key, nil)
end

return M
