--!strict
-- The hub's shared cache (`hub.cache` in kv) and the ownership it carries. Every window reads and writes one cache: each
-- write has an id, a write that lands while this block's snapshot is older is adopted whole first, and a local edit no
-- write has stored is kept and applied again to the board it adopts (`keepCache`, `persistWhole`, `adoptShared`).
-- Tandem's flags join one way across windows, and the guard every effect on a branch runs (`carryOn`, `syncOwnership`,
-- `ownershipChecked`) stops an agent fix still being set up for a PR Tandem has taken. Also `hub.added` and `hub.status`.
local Host = require("../host")
local Model = require("./model")
local Runtime = require("./runtime")
local State = require("./state")
local Sync = require("./sync")

type Block = Runtime.Block
type AgentFlight = Runtime.AgentFlight
type Replay = Runtime.Replay

local draw, announce = Runtime.draw, Runtime.announce

local KV_CACHE, KV_ADDED, KV_STATUS = "hub.cache", "hub.added", "hub.status"
local CACHE_CAP_BYTES = 1024 * 1024

local function kvGet(key: string): any
	local ok, value = pcall(Host.kv.get, key)
	return if ok then value else nil
end

-- The cache other windows (or an earlier run) stored, if it is a valid schema 1, and whether the store could be read at
-- all (false: it threw, which is not the same as holding no valid cache).
local function readCache(): (Sync.Cache?, boolean)
	local ok, raw = pcall(Host.kv.get, KV_CACHE)
	if not ok then return nil, false end
	return Sync.load(raw), true
end

-- The `writeId` of a stored cache ("" when it has none, or the store holds no valid cache).
local function storedId(cache: Sync.Cache?): string
	local id = if cache then (cache :: any).writeId else nil
	return if type(id) == "string" then id else ""
end

-- Facts only this machine knows. `tandem` is the block's own read of Tandem, applied by `withTandem`.
local function readLocal(): Sync.Local
	local added: Sync.Added = {}
	local raw = kvGet(KV_ADDED)
	if type(raw) == "table" then
		for key, ref in raw do
			if type(key) == "string" and type(ref) == "table" and type(ref.repo) == "string" and type(ref.number) == "number" then
				added[key] = { repo = ref.repo, number = ref.number }
			end
		end
	end
	return { added = added, tandem = {}, landing = {} }
end

-- `prs` with Tandem's flag set. The list a fixture hands over is shared data, so a flagged PR is a copy of it.
local function flagged(watched: { [string]: boolean }, prs: { Model.HubPR }): { Model.HubPR }
	local flags = Model.tandemFlags(watched, prs)
	local out: { Model.HubPR } = {}
	for i, pr in prs do
		local want = flags[pr.key] == true
		if pr.tandem == want then
			out[i] = pr
		else
			local copy = table.clone(pr)
			copy.tandem = want
			out[i] = copy
		end
	end
	return out
end

-- The tiny record the window's status segment reads every 2 s, so it never decodes the whole cache.
local function writeStatus(cache: Sync.Cache)
	local counts = cache.counts
	pcall(Host.kv.set, KV_STATUS, {
		refreshedAt = cache.refreshedAt,
		counts = { toReview = counts.toReview, needFixes = counts.needFixes, flashAt = counts.flashAt },
	})
end

-- Every write of `hub.cache` carries a `writeId` no other write has: this window's nonce and a count. It is how a stored
-- cache is told apart from another stored at the same `refreshedAt` (a hand-off keeps the stamp), and it never stands in for
-- GitHub's freshness. A cache stored before ids existed has none, which `storedId` reads as "".
local WINDOW = string.format("%x.%x.%s", Host.time(), math.random(0, 0x7fffffff), (string.gsub(tostring({}), "%W", "")))
local writes = 0

-- Writes the cache under the size cap. Returns why it failed; memory state stands either way.
local function persist(b: Block): string?
	local cache = b.cache
	if not cache then return nil end
	writes += 1
	local id = WINDOW .. "#" .. writes
	local stored: { [string]: boolean } = {}
	local ok, err = pcall(function()
		local value = Sync.save(cache, CACHE_CAP_BYTES, function(value: any): number return #Host.json.encode(value) end)
		value.writeId = id
		for _, pr in value.prs do stored[pr.key] = true end
		Host.kv.set(KV_CACHE, value)
	end)
	if ok then
		b.unsaved = false
		b.held = id
		-- A write represents an edit only when it is on the board and the stored PRs agree with the board about its PR (a PR
		-- the size cap evicted, or one the board lacks, is not stored with the edit's effect): the rest stay for a later replay.
		-- An edit the write holds that took its PR off the board (a close, a merge, a removal) was made after the older edits of
		-- that PR and supersedes them, so those go too: the PR reopening on the same head must not bring a pending merge back.
		-- A cap that omits a PR retires nothing: the board still holds that PR, so no held edit took it off.
		local held: { [number]: boolean } = {}
		local removedAt: { [string]: number } = {}
		for i, replay in b.replays do
			if replay.applied and replay.present == (stored[replay.key] == true) then
				held[i] = true
				if not replay.present then removedAt[replay.key] = i end
			end
		end
		local kept: { Replay } = {}
		for i, replay in b.replays do
			if not held[i] and i > (removedAt[replay.key] or 0) then table.insert(kept, replay) end
		end
		b.replays = kept
		b.seen[id] = true
		writeStatus(cache)
	end
	return if ok then nil else tostring(err)
end

-- Puts the cache's PRs and its Needs fixes and To review counts back in step with the board after Tandem's flags move a PR.
-- The counts cover every PR, not the grid a search or repo filter leaves. `flashAt` stays: a count that fell is no alert.
local function recount(b: Block)
	local cache = b.cache
	if not cache then return end
	cache.prs = b.s.prs
	local toReview, needFixes = 0, 0
	for _, pr in cache.prs do
		local column = Model.classify(pr, b.s.now)
		if column == "to_review" then toReview += 1 end
		if column == "needs_fixes" then needFixes += 1 end
	end
	cache.counts = { toReview = toReview, needFixes = needFixes, flashAt = cache.counts.flashAt }
end

local function cachedAt(b: Block): number?
	return if b.cache then Model.epoch(b.cache.refreshedAt) else nil
end

-- Ownership runs one way. A PR the other window's cache flags joins this block's set (it may be a hand-off this block's
-- own reads predate, so a read that began before cannot name it and is read again). The other window's silence never
-- clears one: only a successful read of Tandem here does, whatever the cache's age.
-- An ownership-bearing write whose id this block has not met is also remembered by the PRs it flags (`b.heard`), even when
-- the block held every flag already: a hand-off Tandem took again moves nothing here, and a local save that follows
-- replaces the stored id, so only this record tells a read of Tandem that began earlier that it predates the write.
local function joinOwnership(b: Block, shared: Sync.Cache)
	local took = false
	local flags: { string } = {}
	for _, pr in shared.prs do
		local key = string.lower(pr.repo) .. "#" .. pr.number
		if pr.tandem then
			table.insert(flags, key)
			if not b.watched[key] then b.watched[key], took = true, true end
		end
	end
	local id = storedId(shared)
	if id ~= "" and not b.seen[id] then
		b.seen[id] = true
		if #flags > 0 then table.insert(b.heard, flags) end
	end
	if took then b.handoffs += 1 end
end

-- The cache another window stored, if it is as new as this block's own (`strict`: newer). Adopting a cache takes the
-- strictly newer one; joining its ownership also takes one stored at the same time, because a hand-off keeps the
-- cache's own `refreshedAt`, so the window that took it leaves the same stamp this block holds.
-- The second result is false when the store could not be read: "no cache" is then a guess, not an answer.
local function sharedCache(b: Block, strict: boolean): (Sync.Cache?, boolean)
	local shared, readable = readCache()
	if not shared or b.retired[storedId(shared)] then return nil, readable end
	local theirs, mine = Model.epoch(shared.refreshedAt), cachedAt(b)
	if not theirs then return nil, true end
	if mine == nil or theirs > mine or (not strict and theirs == mine) then return shared, true end
	-- A cache stored at this block's own stamp that is not the one this block last stored or adopted is another window's
	-- (a hand-off or a pending merge keeps the stamp) and may hold data this board lacks, whether or not an ownership is
	-- unsaved, so it is adopted whole before anything writes (the store's own id decides, not its stamp).
	if strict and theirs == mine and storedId(shared) ~= (b.held or "") then return shared, true end
	return nil, true
end

-- The identity of the cache the store holds now, taken before a successful read of Tandem clears a flag. `readable` is false
-- when the store cannot be read at all; `id` is nil when it holds no valid cache. If that answer's own save fails, this id
-- is the one retired (`b.retired`), and `sharedCache` ignores a cache that carries it. It is captured before anything is
-- joined or written, so a write that lands later, whatever its stamp, has another id and is never retired.
local function storedNow(): (boolean, string?)
	local ok, raw = pcall(Host.kv.get, KV_CACHE)
	if not ok then return false, nil end
	local cache = Sync.load(raw)
	return true, if cache then storedId(cache) else nil
end

-- Joins the ownership of a shared cache stored at this block's cache's time or later; an older one joins nothing. Returns
-- the cache it joined, if any.
local function joinShared(b: Block): (Sync.Cache?, boolean)
	local shared, readable = sharedCache(b, false)
	if shared then joinOwnership(b, shared) end
	return shared, readable
end

-- Whether a write another window made after a read of Tandem began (`b.heard`) flags a PR that read's answer omits. That
-- answer predates the write, so it cannot clear the flag even when this block already held it.
local function renewed(b: Block, watched: { [string]: boolean }): boolean
	for _, flags in b.heard do
		for _, key in flags do
			if not watched[key] then return true end
		end
	end
	return false
end

-- Puts Tandem's flags from this block's set onto its PRs. Positive only: a flag is set here, never cleared. Returns
-- whether a PR moved.
local function flagPrs(b: Block): boolean
	local flags = Model.tandemFlags(b.watched, b.s.prs)
	local moved = false
	for _, pr in b.s.prs do
		if flags[pr.key] and not pr.tandem then pr.tandem, moved = true, true end
	end
	return moved
end

-- The ownership half of every guard: joins what another window stored at this cache's time or later, flags the PRs and
-- recounts. It is read-only toward everything else (no flight is touched, nothing drawn or persisted) so `carryOn` can
-- call it. A sample board stays wholly local. Returns whether a PR moved, and whether the store could be read: when it could
-- not, no other window's ownership was checked, and a guard must not let an effect on a branch begin or go on.
local UNCHECKED = "Tandem's ownership couldn't be checked"
local TANDEM_OWNS = "Tandem watches this pull request" -- why a push or merge on its branch is refused

local function joinOwned(b: Block): (boolean, boolean)
	if b.fixture or b.closed then return false, true end
	local _, readable = joinShared(b)
	if not flagPrs(b) then return false, readable end
	State.project(b.s)
	recount(b)
	return true, readable
end

local function currentFlight(b: Block, flight: AgentFlight): boolean
	return not b.closed and b.agentFlight == flight and not flight.settled and not flight.stopping
end

-- True while the fix may go on. One owner per branch: a fix still being set up for a PR Tandem has taken (no engine
-- yet, so no worktree is held) ends as stopped, as Stop would end it, and never starts. A running engine is Stop's.
-- Ownership another window stored since the last callback joins first, so every continuation of the setup sees it, and
-- a PR that move flagged is drawn here even when this fix goes on. `superseded` is a successful read of Tandem that has
-- just decided ownership: the stored cache is older than that answer, so it joins nothing and cannot restore a flag the
-- answer cleared. A store that cannot be read ends the setup as failed: ownership could not be checked, so no step goes on.
local function carryOn(b: Block, cx: BlockCx, flight: AgentFlight, superseded: boolean?): boolean
	if not currentFlight(b, flight) then return false end
	if flight.engine or flight.starting then return true end
	local moved, readable = false, true
	if not superseded then moved, readable = joinOwned(b) end
	local pr = State.prOf(b.s, flight.key)
	local owned = pr ~= nil and pr.tandem
	if readable and not owned then
		if moved then draw(b, cx) end
		-- A render that raised has closed the block and settled this flight: nothing may go on to start an engine.
		return currentFlight(b, flight)
	end
	flight.stopping = true
	if flight.cancel then flight.cancel() end
	flight.settled = true
	b.agentFlight = nil
	State.agentOutcome(b.s, flight.key, if owned then { kind = "stopped" } else { kind = "failed", reason = UNCHECKED })
	draw(b, cx)
	return false
end

-- `carryOn` for the current flight, if any: called wherever a board is installed whole, so setup that belongs to a PR the
-- new board marks as Tandem's ends at once.
local function reconcileFlight(b: Block, cx: BlockCx)
	local flight = b.agentFlight
	if flight then carryOn(b, cx, flight) end
end

-- The check before an effect on a branch: ownership another window stored joins, and a fix still being set up is
-- reconciled with it. Run at every action's dispatch and before each command of a push. Returns whether a PR moved, and
-- whether ownership could be checked (see `joinOwned`).
local function syncOwnership(b: Block, cx: BlockCx): (boolean, boolean)
	if b.fixture then return false, true end
	local moved, readable = joinOwned(b)
	reconcileFlight(b, cx)
	return moved, readable
end

-- The check at the point a direct effect on a PR's branch is decided (Update branch, merge when ready, a push): ownership
-- another window stored joins first, and when the store cannot be read the effect is refused, since a hand-off may be in it.
-- `what` completes "Couldn't …".
local function ownershipChecked(b: Block, cx: BlockCx, what: string): boolean
	local _, readable = joinOwned(b)
	if readable then return true end
	cx:toast("error", "Couldn't " .. what .. ": " .. UNCHECKED)
	return false
end

-- Applies the local edits no write has stored to the board's PRs again, each only while its PR is still there on the head
-- it was made on, and records which of them are on the board now (`applied`, `present`). `since` is for a complete board
-- (an adopted cache, or this window's own refresh answer): the time its PR data was requested from GitHub. A PR on it at
-- another head means the head advanced for good, so that edit is dropped, and a refresh answer from before the advance cannot
-- make it eligible again, but only when the snapshot is provably the later one: its request began after the edit's head was
-- seen. A snapshot stamped later can still be a delayed request that carries an older head, so a stamp alone proves nothing,
-- and a board with no `since` drops nothing. An edit whose PR is absent or on another head, unproven, waits. A pending queue
-- merge whose PR a provably later snapshot reports dropped from the queue, on the same head, is retired without applying: GitHub
-- removed the entry, so nothing is in flight to cancel. Returns whether one applied.
local function replayEdits(b: Block, since: number?): boolean
	local replayed = false
	local kept = {}
	for _, replay in b.replays do
		local pr = State.prOf(b.s, replay.key)
		local moved = pr ~= nil and pr.headOid ~= replay.head
		local dropped = replay.queued == true and pr ~= nil and not moved and since ~= nil and since > replay.at
			and pr.mergeFailure ~= nil and pr.mergeFailure.kind == "queue"
		if not dropped then
			replay.applied = pr ~= nil and not moved
			if replay.applied then
				replay.edit()
				replay.present = State.prOf(b.s, replay.key) ~= nil
				replayed = true
			end
			if not (moved and since ~= nil and since > replay.at) then table.insert(kept, replay) end
		end
	end
	b.replays = kept
	return replayed
end

-- The time a stored cache's PR data was requested from GitHub, which a refresh records (`sinceAt`): every head in it was
-- seen after that. A cache without it (stored before it existed, or only restamped by a hand-off) has no provenance.
local function requestedAt(cache: Sync.Cache): number?
	local at = (cache :: any).sinceAt
	return if type(at) == "number" then at else nil
end

-- Lays `shared`, a complete cache another window stored, onto this block as its board: its ownership joins, its PRs (flagged
-- by every flag this block holds) become the board, and the local edits no write has stored are applied to it again. It reads
-- no store and draws nothing. Returns whether a flag moved on a PR and whether an edit applied.
local function layShared(b: Block, cx: BlockCx, shared: Sync.Cache): (boolean, boolean)
	local now = Host.time()
	joinOwnership(b, shared)
	local prs = flagged(b.watched, shared.prs)
	local moved = false
	for i, pr in prs do
		if pr ~= shared.prs[i] then moved = true; break end
	end
	shared.prs = prs
	announce(b, cx, b.cache, prs, now)
	b.cache = shared
	b.held = storedId(shared)
	State.replace(b.s, prs, now, shared.refreshedAt)
	State.setMerged(b.s, shared.merged)
	return moved, replayEdits(b, requestedAt(shared))
end

-- The last read before a write of the board's snapshot. A complete cache another window stored since this block last read the
-- store (newer than the board's, or another at its stamp) is the board's newer base: it is laid on whole, `reapply` puts the
-- caller's own results back on it (they are applied only where still valid), and the retained edits apply to it again, so the
-- write never lays this block's older snapshot over it. One read, no retry, and nothing in here reads the store again or draws,
-- so the caller writes at once. `answered` is a successful read of Tandem that has just decided ownership: the cache this block
-- already holds joins nothing, so it cannot restore a flag the answer cleared. Returns whether the store could be read (when
-- it could not, "no cache" is a guess and nothing may be written) and whether a cache was laid on or a flag moved on a PR, which
-- a fix still being set up must be reconciled with (`persistWhole` does, after the write).
local function reconcileStore(b: Block, cx: BlockCx, reapply: (() -> ())?, answered: boolean?): (boolean, boolean)
	local shared, readable = sharedCache(b, false)
	if not shared and not readable then return false, false end
	local changed = false
	if shared then
		local mine = cachedAt(b)
		if mine == nil or (Model.epoch(shared.refreshedAt) :: number) > mine or storedId(shared) ~= (b.held or "") then
			local moved, replayed = layShared(b, cx, shared)
			if reapply then reapply() end
			if moved or replayed then
				recount(b)
				b.unsaved = true
			end
			changed = true
		elseif not answered then
			joinOwnership(b, shared)
		end
	end
	if flagPrs(b) then
		State.project(b.s)
		recount(b)
		changed = true
	end
	return true, changed
end

-- Every write of a board snapshot that follows a local change goes through here: `reconcileStore`, then `persist`, with
-- nothing between the two that reads the store or draws. The caller has already joined ownership and reconciled the flight, so
-- a redraw that closes the block comes before the write; ownership only the last read brought is reconciled after the write.
-- Returns whether the write was safe to make (false: the store could not be read, nothing was written, and the caller decides
-- what stands) and why the write failed, if it did. A refresh answer is not written here: it reads the store last itself
-- (`startRefresh`) and merges against the complete cache it finds, since its snapshot is stamped newer than any stored before it.
local function persistWhole(b: Block, cx: BlockCx, reapply: (() -> ())?, answered: boolean?): (boolean, string?)
	if b.closed then return false, nil end
	if not b.cache then return true, nil end
	local readable, moved = reconcileStore(b, cx, reapply, answered)
	if not readable then return false, nil end
	local board = b.cache :: Sync.Cache
	board.prs = b.s.prs
	local why = persist(b)
	local flight = b.agentFlight
	if moved and flight then carryOn(b, cx, flight, answered) end
	return true, why
end

-- Installs `shared`, a cache another window stored that `sharedCache` took, as this block's board; `adoptShared` says when it
-- may go on and why.
local function installShared(b: Block, cx: BlockCx, shared: Sync.Cache, hold: boolean?): boolean
	local moved, replayed = layShared(b, cx, shared)
	reconcileFlight(b, cx)
	-- The redraw may have closed the block: nothing is stored or counted after that.
	if b.closed then return false end
	if moved or replayed then
		recount(b)
		if hold then
			b.unsaved = true
		else
			local safe, why = persistWhole(b, cx)
			if why or not safe then
				b.unsaved = true
				return false
			end
		end
	end
	return true
end

-- Takes another window's newer cache, so windows share one refresh. The ownership this block restores onto it is stored
-- at once, unless `hold`: a read of Tandem then writes nothing here and marks the block `unsaved`, so the successful answer's
-- own save is the only write and no intermediate cache is left for a later guard to join. An answer that is dropped as
-- stale or fails closed writes nothing either; the mark waits for the next successful answer, or any other write.
-- Returns whether the caller may go on to edit and store the board. It may not when the block closed, or when the save of
-- the restored ownership failed: another window may have stored a newer cache meanwhile, and this block's snapshot is
-- then older than the store. The ownership stays in memory (`unsaved`), and the next guard adopts the newer cache.
-- It may not either when the store cannot be read, whether or not `unsaved`: "no cache" is then a guess, and the store may
-- hold a distinct or newer cache this board lacks, so nothing that writes a snapshot goes on until a read succeeds and adopts
-- it. A caller that cannot write one (`rearm`) may ignore the result.
-- A local edit that no write has stored (`b.replays`) is applied to the adopted board again, so the cache that is stored next
-- carries it.
local function adoptShared(b: Block, cx: BlockCx, hold: boolean?): boolean
	local shared, readable = sharedCache(b, true)
	if not shared then return readable end
	return installShared(b, cx, shared, hold)
end

-- Puts the ownership this block holds onto its PRs now, so the card and the action guards are safe before any read or
-- refresh answers: a fix still being set up for a PR that just became Tandem's ends as stopped (`carryOn`), and the
-- counts follow. The flight is reconciled even when no flag moved here, since an adopted cache may already have set
-- the flag. Positive only: a flag is set here, never cleared; a successful read of Tandem is the one that clears.
-- Nothing is persisted; the caller decides what to store. Returns whether a PR moved.
local function applyOwnership(b: Block, cx: BlockCx): boolean
	local moved = flagPrs(b)
	local flight = b.agentFlight
	if flight then carryOn(b, cx, flight) end
	-- `carryOn` draws, and the draw may have closed the block: nothing is projected or counted after that.
	if b.closed or not moved then return false end
	State.project(b.s)
	recount(b)
	return true
end

-- Writes hub.added. Returns why it failed.
local function writeAdded(added: Sync.Added): string?
	local ok, err = pcall(Host.kv.set, KV_ADDED, added)
	return if ok then nil else tostring(err)
end

-- Keeps the cache in step with a change the viewer just made to the board. `edit` is that change, applied here and
-- nowhere else (nil when the caller's change is ownership, which `applyOwnership` carries). A cache another window
-- stored strictly newer than this block's own becomes the board first, with its stamp and its ownership, and `edit`
-- lands on it: the write never lowers `refreshedAt` and never lays this block's older PR snapshot over newer data. The
-- change says nothing about Tandem, so ownership stored at this stamp or later joins and is never written back as false.
-- `head` is the head of PR `key` the action began on, taken before its external effect. The edit applies only while the board's
-- PR still has that head: an adopted cache that moved it knows better, and the stale edit is neither applied nor kept.
-- An `edit` that no write stores (the store could not be read, or the save failed) is kept with that head, and
-- `adoptShared` applies it to the cache it adopts later, while that head stands. A write clears only the edits it holds (see
-- `persist`), so an edit whose PR a later cache omits stays for the refresh that brings the PR back. `queued` is an edit that
-- sets a pending merge in the repo's queue (see `Replay`).
local function keepCache(b: Block, cx: BlockCx, edit: (() -> ())?, key: string?, head: string?, queued: boolean?)
	local safe = true
	if b.cache and not b.fixture then safe = adoptShared(b, cx) end
	-- Adopting a cache redraws, and the redraw may have closed the block: no edit and no write follow.
	if b.closed then return end
	if edit then
		local pr = if key then State.prOf(b.s, key) else nil
		local tracked = key ~= nil and head ~= nil and b.cache ~= nil and not b.fixture
		if pr == nil and tracked then
			-- The PR is absent (a capped cache omits it): the edit has nothing to land on, and is not applied to the absence. It
			-- waits, unapplied, for the PR to return on this head. Its time is now, which no snapshot requested before it can pass.
			table.insert(b.replays, {
				key = key :: string, head = head :: string, at = Host.time(), edit = edit, applied = false, present = true, queued = queued,
			})
		elseif not (pr and head and pr.headOid ~= head) then
			edit()
			if pr and head and b.cache and not b.fixture then
				table.insert(b.replays, {
					key = pr.key, head = head, at = cachedAt(b) or Host.time(), edit = edit,
					applied = true, present = State.prOf(b.s, pr.key) ~= nil, queued = queued,
				})
			end
		end
	end
	if not b.cache then return end
	if b.fixture then
		joinShared(b)
		applyOwnership(b, cx)
		if b.closed then return end
		b.cache.prs = b.s.prs
		persist(b)
		return
	end
	-- The write reads the store once more first (`persistWhole`): a cache another window stored since the first adoption (a
	-- pending merge, a flag) is the board's newer base, so it is installed whole and the retained edits, this one included, are
	-- applied to it again. Nothing reads the store or draws between that read and the write. An unreadable store writes nothing,
	-- as at the first read, and so does a first adoption that failed to save: the edit stays on the board, but the store may
	-- hold a cache newer than this board, and the write would lay this one over it. The last read still installs that cache.
	if safe then
		applyOwnership(b, cx)
		-- So does applying ownership: a closed block writes nothing.
		if b.closed then return end
		persistWhole(b, cx)
	else
		reconcileStore(b, cx)
		local board = b.cache
		if board then board.prs = b.s.prs end
		applyOwnership(b, cx)
	end
end

return {
	KV_CACHE = KV_CACHE,
	UNCHECKED = UNCHECKED,
	TANDEM_OWNS = TANDEM_OWNS,
	kvGet = kvGet,
	readCache = readCache,
	storedId = storedId,
	readLocal = readLocal,
	writeAdded = writeAdded,
	flagged = flagged,
	writeStatus = writeStatus,
	persist = persist,
	recount = recount,
	cachedAt = cachedAt,
	joinOwnership = joinOwnership,
	sharedCache = sharedCache,
	storedNow = storedNow,
	joinShared = joinShared,
	renewed = renewed,
	flagPrs = flagPrs,
	joinOwned = joinOwned,
	carryOn = carryOn,
	reconcileFlight = reconcileFlight,
	syncOwnership = syncOwnership,
	ownershipChecked = ownershipChecked,
	replayEdits = replayEdits,
	persistWhole = persistWhole,
	adoptShared = adoptShared,
	applyOwnership = applyOwnership,
	keepCache = keepCache,
}
