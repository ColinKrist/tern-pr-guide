--!strict
-- The board's live data: the probe, refresh and checks timers armed from `Sync.schedule` (`rearm`), each answer laid onto
-- the newest shared cache there is before it is stored, a refresh asked for now (`refetch`), the sample board's ⌘R,
-- which steps through recorded refreshes instead, and a pull request's check list for the checks popover and the fixes
-- page (`loadCheckList`), read again on the checks timer while the popover is open and a check is unfinished.
local AutoLandRun = require("./auto-land-run")
local Checks = require("./checks")
local FilterStore = require("./filter-store")
local CheckFilter = require("./check-filter")
local Host = require("../host")
local HubTandem = require("./tandem")
local Lookups = require("./lookups")
local Model = require("./model")
local Preload = require("./preload")
local Prepare = require("./prepare")
local Runtime = require("./runtime")
local State = require("./state")
local Store = require("./store")
local Sync = require("./sync")

type Block = Runtime.Block

local FIXTURES, draw, announce, revealSelected, reasonOf = Runtime.FIXTURES, Runtime.draw, Runtime.announce, Runtime.revealSelected, Runtime.reasonOf
local KV_CACHE, adoptShared, cachedAt, readLocal, writeAdded = Store.KV_CACHE, Store.adoptShared, Store.cachedAt, Store.readLocal, Store.writeAdded
local reconcileFlight, sharedCache, storedId, joinOwnership = Store.reconcileFlight, Store.sharedCache, Store.storedId, Store.joinOwnership
local replayEdits, recount, persist, joinShared = Store.replayEdits, Store.recount, Store.persist, Store.joinShared
local applyOwnership, persistWhole, flagged = Store.applyOwnership, Store.persistWhole, Store.flagged
local loadMerges, detectMerges, loadFlakes = Lookups.loadMerges, Lookups.detectMerges, Lookups.loadFlakes
local loadTandem = HubTandem.loadTandem

-- Sync: the cache, the timers and the live data ----------------------------------------------------------
-- Visibility is not observable from a block, so the hub polls for as long as the block exists (parked or in a
-- background tab). A closed block is found out by a failing render, which ends every chain.

-- The open popover's pull request while its list has a check unfinished: the checks timer reads it again.
local function watchedList(b: Block): Model.HubPR?
	local pop = b.s.checks
	if pop == nil then return nil end
	local load = State.checkLoad(b.s, pop.key)
	if load == nil or load.state ~= "loaded" or not Checks.unfinished(load.list) then return nil end
	return State.prOf(b.s, pop.key)
end

-- The pull requests whose checks are running, for the checks timer; `popover` adds the popover's while its list waits.
local function running(b: Block, popover: boolean?): { string }
	local ids = {}
	for _, pr in b.s.prs do
		if pr.checks.state == "pending" then table.insert(ids, pr.id) end
	end
	local watched = if popover then watchedList(b) else nil
	if watched and table.find(ids, watched.id) == nil then table.insert(ids, watched.id) end
	return ids
end

local onProbe: (b: Block, cx: BlockCx) -> ()
local onRefresh: (b: Block, cx: BlockCx) -> ()
local onChecks: (b: Block, cx: BlockCx) -> ()
local refetchSoon: (b: Block, cx: BlockCx) -> ()

-- Cancels the named timer's old handle, then arms a one-shot after `seconds` (nil leaves it off).
local function arm(b: Block, cx: BlockCx, name: "probe" | "refresh" | "checks" | "debounce", seconds: number?, fn: (Block, BlockCx) -> ())
	local timers = b.timers :: any
	local old: TimerHandle? = timers[name]
	if old then old:cancel() end
	timers[name] = nil
	if seconds == nil or b.closed then return end
	timers[name] = Host.timer(math.max(1, math.ceil(seconds * 1000)), function()
		timers[name] = nil
		if b.closed then return end
		fn(b, cx)
	end)
end

-- Arms the probe, refresh (as the debounce while a change or focus waits) and checks timers from the schedule.
local function rearm(b: Block, cx: BlockCx)
	if b.fixture or b.closed then return end
	adoptShared(b, cx)
	if b.closed then return end
	local sched = b.sched
	local last, tried = cachedAt(b), sched.refreshTried
	local plan = Sync.schedule({
		now = Host.time(), refreshedAt = if last and tried then math.max(last, tried) else (last or tried),
		refreshing = b.flights.refresh, probedAt = sched.probedAt, probeChanged = sched.probeChanged,
		focusedAt = sched.focusedAt, checksAt = sched.checksAt, running = running(b, true),
	})
	local early = sched.probeChanged or sched.focusedAt ~= nil
	arm(b, cx, "probe", plan.probe, onProbe)
	arm(b, cx, "refresh", if early then nil else plan.refresh, onRefresh)
	arm(b, cx, "debounce", if early then plan.refresh else nil, onRefresh)
	arm(b, cx, "checks", plan.checks, onChecks)
end

-- Reads the check list of `key` at its head commit, unless a read is under way or (without `again`) it is already
-- loaded. The sample board answers from `fixtures/hub/check-lists.luau`.
local function loadCheckList(b: Block, cx: BlockCx, key: string, again: boolean?)
	local s = b.s
	local pr = State.prOf(s, key)
	if pr == nil or b.closed then return end
	local load = State.checkLoad(s, key)
	if load and load.state == "loading" then return end
	if load and load.state == "loaded" and not again then return end
	local head = pr.headOid
	if b.fixture then
		local sample: any = require("../../fixtures/hub/check-lists")
		return State.setCheckLoad(s, key, head, { state = "loaded", list = sample.forPr(pr) })
	end
	-- A list on show stays while it is read again; only a first read shows the placeholder rows.
	if not (load and load.state == "loaded") then State.setCheckLoad(s, key, head, { state = "loading" }) end
	b.github.checkList(pr.id, function(list, err)
		if b.closed then return end
		s.now = Host.time()
		State.setCheckLoad(s, key, head, if list then { state = "loaded", list = list } else { state = "failed", reason = if err then reasonOf(err.message) else "no answer" })
		rearm(b, cx)
		draw(b, cx)
	end)
end

onProbe = function(b, cx)
	if b.flights.probe then return end
	b.flights.probe = true
	b.github.probe(b.sched.lastModified, function(value, err)
		b.flights.probe = false
		if b.closed then return end
		b.sched.probedAt = Host.time()
		-- A failed probe is "no change", never an error on screen and never a retry before the next minute: the
		-- viewer's gh token often lacks the `notifications` scope, so /notifications answers 404, and the
		-- five-minute refresh still runs. The first answer only sets the validator.
		if value then
			if value.changed and b.sched.lastModified ~= nil then b.sched.probeChanged = true end
			if value.lastModified then b.sched.lastModified = value.lastModified end
		end
		rearm(b, cx)
		draw(b, cx)
	end)
end

local startRefresh: (b: Block, cx: BlockCx) -> ()

-- After a refresh: a pull request just added by link is selected and brought into view, or, when GitHub
-- didn't return it, forgotten with the reason.
local function showAdded(b: Block, cx: BlockCx)
	local ref = b.show
	if not ref then return end
	b.show = nil
	local pr = State.find(b.s, ref.repo, ref.number)
	if pr and State.show(b.s, pr.key) then
		FilterStore.save(b, cx)
		revealSelected(b, cx)
		return
	end
	local added = readLocal().added
	for key, entry in added do
		if entry.number == ref.number and string.lower(entry.repo) == string.lower(ref.repo) then added[key] = nil end
	end
	writeAdded(added)
	cx:toast("error", "Couldn't add #" .. ref.number .. ": GitHub has no pull request " .. ref.repo .. "#" .. ref.number)
end

startRefresh = function(b: Block, cx: BlockCx)
	b.flights.refresh = true
	b.s.loading = true
	-- Every head in the answer was seen after this: the cache stores it (`sinceAt`), so a window adopting it can tell a snapshot
	-- that is the later word on a head from one that only finished later.
	local requested = Host.time()
	loadTandem(b, cx)
	-- A read of Tandem that answered at once may have drawn, and the draw closed the block: nothing is read or asked after that.
	if b.closed then return end
	local refs: { Model.PRRef } = {}
	for _, ref in readLocal().added do table.insert(refs, ref) end
	b.github.refresh({ added = refs, previous = b.s.prs, checkNames = State.ignoredRepositories(b.s) }, function(fresh, err)
		b.flights.refresh = false
		if b.closed then return end
		local now = Host.time()
		b.sched.refreshTried = now
		-- The answer lands on the newest cache there is, looked at again now: another window's may have landed while the request
		-- was out, and `Sync.merge` carries what only that cache holds (a pending merge). When the store cannot be read, or the
		-- adoption could not be stored, the answer is dropped: it merges, stores and chains nothing, and the schedule (which
		-- `refreshTried` has moved) tries again later. The answer's own save is the one write (`hold`).
		local safe = not fresh or adoptShared(b, cx, true)
		if b.closed then return end
		local facts: Sync.Local = { added = {}, tandem = {}, landing = {} }
		local canonMoved = false
		local shared: Sync.Cache? = nil
		if safe and fresh then
			facts = readLocal()
			facts.landing = AutoLandRun.marks()
			local canon, moved = State.canonicalAdded(facts.added, fresh.prs)
			facts.added, canonMoved = canon, moved
			-- A fix still being set up for a PR another window has taken ends before the answer is merged: ending it draws, so it
			-- comes before the last read of the store, and nothing between that read and the write draws or reads again.
			reconcileFlight(b, cx)
			if b.closed then return end
			-- The last read. The answer is dropped, nothing merged or committed, when the store cannot be read.
			shared, safe = sharedCache(b, false)
		end
		if not safe then
			b.s.loading = false
			b.s.error = { operation = KV_CACHE, message = "the cache couldn't be read, so the refresh was not stored" }
			rearm(b, cx)
			draw(b, cx)
			return
		end
		if not fresh then
			b.s.loading = false
			b.s.error = { operation = if err then err.operation else "hub", message = reasonOf(if err then err.message else "no answer"), rateLimit = if err then err.rateLimit else nil }
		else
			if canonMoved then writeAdded(facts.added) end
			-- A complete cache another window stored since this block last read the store (newer than the board's, or another at
			-- its stamp) is the answer's newer base: the answer is merged against it, whole, and never against the older board. The
			-- answer stays GitHub's word on every PR; what the base adds is its ownership and the pending merges it holds. Ownership
			-- joins either way, so the stored cache cannot erase a flag; a read of Tandem still out predates it and is read again.
			local previous = b.cache
			local owned = b.handoffs
			if shared then
				local mine = cachedAt(b)
				if mine == nil or (Model.epoch(shared.refreshedAt) :: number) > mine or storedId(shared) ~= (b.held or "") then
					previous, b.held = shared, storedId(shared)
				end
				joinOwnership(b, shared)
			end
			facts.tandem = Model.tandemFlags(b.watched, fresh.prs)
			local cache = Sync.merge(fresh, previous, facts, now)
			cache.lastModified = b.sched.lastModified
			local stamped: any = cache
			stamped.sinceAt = requested
			FilterStore.load(b, cx, fresh.viewer)
			announce(b, cx, b.cache, cache.prs, now)
			b.cache = cache
			b.sched.probeChanged, b.sched.focusedAt = false, nil
			State.replace(b.s, cache.prs, now, cache.refreshedAt)
			State.setMerged(b.s, cache.merged)
			-- This answer may predate a local edit no write has stored (a close whose save failed): it lays that PR back, so the
			-- still-valid retained edits apply again before the counts and the write, which then store their effects.
			if replayEdits(b, requested) then recount(b) end
			local why = persist(b)
			if why then b.s.error = { operation = KV_CACHE, message = "the cache couldn't be saved: " .. why } end
			-- Ownership only the last read brought is reconciled with a fix still being set up after the write, as `persistWhole`
			-- does. The redraw may have closed the block: nothing is read, queued or armed after that.
			if b.handoffs ~= owned then reconcileFlight(b, cx) end
			if b.closed then return end
			showAdded(b, cx)
			Prepare.run(b, cx)
			Preload.run(b, cx)
			AutoLandRun.run(b, cx, true, refetchSoon)
			if b.closed then return end
			loadMerges(b)
			detectMerges(b, cx)
			loadFlakes(b, cx)
			if not b.closed then CheckFilter.read(b, cx, nil) end
			-- An open fixes page whose head moved (an Update branch, an empty commit) reads the new head's check list, so its
			-- failing checks show "Re-running".
			local route = b.s.route
			if route and route.kind == "fixes" then loadCheckList(b, cx, route.key) end
		end
		if b.refetch then
			b.refetch = false
			return startRefresh(b, cx)
		end
		rearm(b, cx)
		draw(b, cx)
	end)
	draw(b, cx)
end

onRefresh = function(b, cx)
	if b.flights.refresh then return end
	local safe = adoptShared(b, cx)
	if b.closed then return end
	-- An unreadable store starts no refresh: its answer could not be reconciled. The attempt counts as tried, so the schedule
	-- waits before the next one.
	if not safe then
		b.sched.refreshTried = Host.time()
		rearm(b, cx)
		draw(b, cx)
		return
	end
	-- Another window refreshed a moment ago: its cache is the answer.
	local last = cachedAt(b)
	if last and Host.time() - last < Sync.DEBOUNCE then
		rearm(b, cx)
		draw(b, cx)
		return
	end
	startRefresh(b, cx)
end

onChecks = function(b, cx)
	if b.flights.checks then return end
	local watched = watchedList(b)
	if watched then loadCheckList(b, cx, watched.key, true) end
	local ids = running(b)
	if #ids == 0 then
		if watched then b.sched.checksAt = Host.time() end
		return rearm(b, cx)
	end
	b.flights.checks = true
	local readChecks = if next(State.ignoredRepositories(b.s)) ~= nil then b.github.checkNames else b.github.checks
	readChecks(ids, function(update, err)
		b.flights.checks = false
		if b.closed then return end
		b.sched.checksAt = Host.time()
		if update then
			-- The results land on the newest cache there is: one stored strictly newer than this block's own becomes the board
			-- first (its stamp stays), and a PR whose head it moved is skipped below like any other moved head.
			local safe = adoptShared(b, cx)
			if b.closed then return end
			-- The results land on whichever board is written: they are applied again to a cache that lands before the write.
			local function land(): boolean
				local changed = false
				for _, pr in b.s.prs do
					local result = update.byId[pr.id]
					-- A moved head means the next full refresh knows better.
					if result and result.headOid == pr.headOid then
						pr.checks = result.checks
						changed = true
					end
				end
				return changed
			end
			if land() then
				b.s.now = Host.time()
				-- A check result is no word on ownership: another window's flags at this stamp or later stay.
				joinShared(b)
				applyOwnership(b, cx)
				-- The redraw may have closed the block: nothing is projected, stored or read after that.
				if b.closed then return end
				State.project(b.s)
				-- Not stored when adopting a newer cache failed to save: the store may hold one this board has not seen. The write
				-- reads the store once more first: a cache that landed since is the base, with these results applied to it again.
				local why: string? = nil
				if safe then
					local _, reason = persistWhole(b, cx, function()
						land()
						State.project(b.s)
					end)
					why = reason
				end
				if why then b.s.error = { operation = KV_CACHE, message = "the cache couldn't be saved: " .. why } end
				loadFlakes(b, cx)
				AutoLandRun.run(b, cx, false, refetchSoon)
				if b.closed then return end
			end
		end
		rearm(b, cx)
		draw(b, cx)
	end)
end

-- A refresh now: after an add, a remove, a merge or a branch update. One running already runs again when it ends.
local function refetch(b: Block, cx: BlockCx)
	if b.fixture or b.closed then return end
	if b.flights.refresh then
		b.refetch = true
	else
		startRefresh(b, cx)
	end
end

-- A refresh a few seconds on, for changes GitHub's search takes a moment to show (a merge, a branch update).
refetchSoon = function(b: Block, cx: BlockCx)
	Host.timer(3000, function()
		if not b.closed then refetch(b, cx) end
	end)
end

-- The sample board's ⌘R: applies the next `refreshes` entry (after the last, the first again) through the same
-- announce path as a live refresh. The entry's earlier board shows first, so the arrival is seen. It never
-- touches kv or `b.cache`: the sample board must not change what the real status segment shows.
local SETTLE_MS = 450

local function fixtureRefresh(prs: { Model.HubPR }): Model.Refresh
	return { prs = prs, viewer = "", rateLimit = nil, calls = {}, truncated = false, partial = nil } :: any
end

local function stepFixture(b: Block, cx: BlockCx)
	if b.flights.refresh then return end
	local data = FIXTURES[b.fixture :: string]()
	local list = data.refreshes
	if not list or #list == 0 then return end
	b.step = b.step % #list + 1
	local source = list[b.step]
	-- Every step's boards carry Tandem's flag, from the same recorded read.
	local entry = table.clone(source)
	entry.prs = flagged(b.watched, source.prs)
	if source.previous then entry.previous = flagged(b.watched, source.previous) end
	local none: Sync.Local = { added = {}, tandem = {}, landing = {} }
	local before: Sync.Cache? = nil
	if entry.previous then
		local built = Sync.merge(fixtureRefresh(entry.previous), nil, none, data.asOf)
		built.prs = entry.previous
		before = built
	end
	local function apply()
		b.flights.refresh = false
		if b.closed then return end
		local acted: { [string]: boolean } = {}
		for key in entry.suppressed do acted[key] = true end
		b.s.acted = acted
		announce(b, cx, before, entry.prs, data.asOf)
		State.replace(b.s, entry.prs, data.asOf, data.asOfIso)
		-- The sample's auto-land is in memory only: every step's board carries it.
		State.stampLanding(b.s, b.sampleLanding)
		draw(b, cx)
	end
	local timers = b.timers :: any
	local running: TimerHandle? = timers.ring
	if running then running:cancel() end
	timers.ring = nil
	b.s.ringed = {}
	if not before then return apply() end
	b.flights.refresh = true
	State.replace(b.s, entry.previous, data.asOf, data.asOfIso)
	draw(b, cx)
	Host.timer(SETTLE_MS, apply)
end

return {
	loadCheckList = loadCheckList,
	rearm = rearm,
	refetch = refetch,
	refetchSoon = refetchSoon,
	stepFixture = stepFixture,
}
