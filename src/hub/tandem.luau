--!strict
-- The hub's side of Tandem, which the web port leaves out (plugin only): reading which PRs Tandem watches and laying
-- that answer onto the board and the shared cache (`loadTandem`), and handing a card off to Tandem (`handoff`). The
-- ownership that answer decides is kept and guarded in hub/store. `src/tandem.luau` runs the `tandem` commands.
local Fetch = require("../fetch")
local Model = require("./model")
local Runtime = require("./runtime")
local State = require("./state")
local Store = require("./store")
local Tandem = require("../tandem")

type Block = Runtime.Block

local draw, reasonOf = Runtime.draw, Runtime.reasonOf
local KV_CACHE = Store.KV_CACHE
local storedNow, adoptShared, joinShared, renewed = Store.storedNow, Store.adoptShared, Store.joinShared, Store.renewed
local applyOwnership, persistWhole, carryOn, flagPrs = Store.applyOwnership, Store.persistWhole, Store.carryOn, Store.flagPrs
local recount, keepCache = Store.recount, Store.keepCache

-- The repository root `cx.cwd` is in, which is the project Tandem knows: `cx.cwd` itself may be a subfolder. Found
-- once and kept; callers that ask while it is being found share the one lookup. `done` gets nil when it cannot be
-- found (nothing is kept, so a later call tries again) or when there is no `cx.cwd`.
local function projectRoot(b: Block, cx: BlockCx, done: (string?) -> ())
	-- A closed block looks nothing up: its callers drop a nil root without a word.
	if b.closed then return done(nil) end
	if b.root then return done(b.root) end
	local dir = cx.cwd
	if not dir then return done(nil) end
	local waiters = b.rootWaiters
	if waiters then return table.insert(waiters, done) end
	local mine: { (string?) -> () } = { done }
	b.rootWaiters = mine
	local settled = false
	local function found(repo: Fetch.Repo?)
		if settled then return end
		settled = true
		if b.rootWaiters == mine then b.rootWaiters = nil end
		local root = if repo then repo.root else nil
		if root then b.root = root end
		for _, waiting in mine do waiting(root) end
	end
	local ok = pcall(Fetch.findRepo, dir, found)
	if not ok then found(nil) end
end

-- Reads which PRs Tandem watches and flags them, one read at a time. With no project folder, or when the read
-- fails, the flags stay as they were (none before a first good read) and the board carries on.
local function loadTandem(b: Block, cx: BlockCx)
	if b.fixture or b.closed or b.flights.tandem or not cx.cwd then return end
	b.flights.tandem = true
	local epoch = b.handoffs
	-- The cache the store held when this read began: a write that lands after it postdates the answer (see `renewed`).
	local _, began = storedNow()
	b.heard = {}
	if began and began ~= "" then b.seen[began] = true end
	local replied = false
	local function apply(watched: { [string]: boolean }?, err: string?)
		if replied then return end
		replied = true
		b.flights.tandem = false
		if b.closed then return end
		-- The answer lands on the newest cache there is: one stored strictly newer than this block's own becomes the board
		-- first, so what is stored next carries its stamp and snapshot and never this block's older ones.
		local before = b.cache
		local readable, superseded = storedNow()
		local safe = adoptShared(b, cx, true)
		-- An unsafe snapshot (the store was unreadable while an adopted cache's ownership is unstored) takes no part: the answer
		-- stores, clears and joins nothing, and the next read decides again.
		if b.closed or not safe then return end
		local adopted = b.cache ~= before
		joinShared(b)
		-- A write another window stored after this read began, flagging a PR the answer omits, is a hand-off even when this
		-- block held the flag already (so joining it moved nothing) and even when a local save has since replaced the stored
		-- id: it counts like one.
		if watched and b.handoffs == epoch and renewed(b, watched) then b.handoffs += 1 end
		-- A hand-off Tandem took while this read was out is newer than the read, which could not name that PR: drop it and read
		-- again. The ownership it joined guards the card at once, and the older answer stores nothing.
		if b.handoffs ~= epoch then
			if applyOwnership(b, cx) or adopted then draw(b, cx) end
			-- Either draw may have closed the block: no further read starts.
			if b.closed then return end
			return loadTandem(b, cx)
		end
		local flags = Model.tandemFlags(watched or b.watched, b.s.prs)
		local changed, cleared, added = false, false, false
		for _, pr in b.s.prs do
			local want = flags[pr.key] == true
			if pr.tandem ~= want then
				changed = true
				if want then added = true else cleared = true end
			end
		end
		-- A clear needs the stored cache's identity, taken above: without it the superseded cache could not be told from a
		-- later write, so the answer changes nothing and the next read decides again.
		if cleared and not readable then
			if adopted then draw(b, cx) end
			return
		end
		-- What the board owned before this answer decided: a clear is final only once the last read before its write succeeded.
		local priorWatched, wasUnsaved = table.clone(b.watched), b.unsaved
		if watched then b.watched = watched end
		for _, pr in b.s.prs do pr.tandem = flags[pr.key] == true end
		if not changed then
			-- Nothing moved, so this answer's save is the one that stores what adoption restored (a failed read stores nothing).
			if watched and b.unsaved then persistWhole(b, cx, nil, true) end
			if adopted then draw(b, cx) end
			return
		end
		local flight = b.agentFlight
		if flight then carryOn(b, cx, flight, true) end
		-- The redraw may have closed the block: nothing is projected, counted or stored after that.
		if b.closed then return end
		State.project(b.s)
		recount(b)
		-- The write reads the store once more first: a complete cache that landed since is the base it writes onto.
		local safe, why = persistWhole(b, cx, nil, true)
		if b.closed then return end
		if not safe then
			-- The store could not be read, so nothing is written, and the clear is not safe: the cache it superseded is still the
			-- store's, joinable, and would bring the flag back at the next guard with no answer behind it. The flags it cleared
			-- return, the board is as it was before the answer, and the next successful answer decides again. A flag it added
			-- stays, unstored.
			if cleared then
				for key in priorWatched do b.watched[key] = true end
				if flagPrs(b) then
					State.project(b.s)
					recount(b)
				end
			end
			b.unsaved = wasUnsaved or added
		elseif why then
			-- Memory state stands. Only this successful read may clear ownership, so the cache it superseded (the one stored
			-- when the answer arrived) must not bring a cleared flag back at the same stamp.
			if cleared and superseded then b.retired[superseded] = true end
			b.s.error = { operation = KV_CACHE, message = "the cache couldn't be saved: " .. why }
		end
		draw(b, cx)
	end
	projectRoot(b, cx, function(root)
		if b.closed or not root then return apply(nil, "The project folder is unknown") end
		local ok, err = pcall(Tandem.watch, root, apply)
		if not ok then apply(nil, tostring(err)) end
	end)
end

-- Hand off to Tandem (A on a card Tandem watches): one `pr-fix` request, sent only now, from the repository root.
-- Tandem's answer is dropped when the card is gone or its head moved meanwhile. A refusal shows Tandem's notice
-- and changes nothing.
local HANDOFF_BUSY = "Handing off to Tandem…"
local function handoff(b: Block, cx: BlockCx, asked: string)
	local s = b.s
	local pr = State.prOf(s, if asked ~= "" then asked else s.selected or "")
	if b.closed or not pr or s.busy[pr.key] then return end
	if b.fixture then return cx:toast("info", "The sample board doesn't hand off to Tandem", pr.key) end
	if not cx.cwd then return cx:toast("error", "Couldn't hand off to Tandem: the project folder is unknown", pr.key) end
	local head, repo, number, key = pr.headOid, pr.repo, pr.number, pr.key
	local reason = Model.handoffReason(pr, s.now)
	State.setBusy(s, key, HANDOFF_BUSY)
	draw(b, cx)
	-- The draw may have closed the block: no root is looked up and nothing is sent.
	if b.closed then return end
	local replied = false
	local function answered(outcome: Tandem.Outcome?, err: string?)
		if replied then return end
		replied = true
		if b.closed then return end
		if s.busy[key] == HANDOFF_BUSY then State.setBusy(s, key, nil) end
		local current = State.prOf(s, key)
		if not current or current.headOid ~= head then return draw(b, cx) end
		if not outcome then
			cx:toast("error", "Couldn't hand off to Tandem: " .. reasonOf(err or "no answer"), key)
		elseif outcome.status == "refused" then
			cx:toast("error", if outcome.notice then outcome.notice.text else "Tandem didn't take this pull request", key)
		else
			current.tandem = true
			b.watched[string.lower(repo) .. "#" .. number] = true
			b.handoffs += 1
			local flight = b.agentFlight
			if flight then carryOn(b, cx, flight) end
			-- Stopping the setup draws, and the draw may have closed the block: nothing is counted, stored or shown after that.
			if b.closed then return end
			State.project(s)
			recount(b)
			keepCache(b, cx)
			if b.closed then return end
			if outcome.notice then cx:toast("info", outcome.notice.text, key) end
		end
		draw(b, cx)
	end
	projectRoot(b, cx, function(root)
		if replied then return end
		local current = State.prOf(s, key)
		-- Nothing is sent for a card that is gone or moved while the root was being found; `answered` settles it quietly.
		if b.closed or not current or current.headOid ~= head then return answered(nil, "stale") end
		if not root then return answered(nil, "the project folder is unknown") end
		local ok, err = pcall(Tandem.handoff, root, repo, number, reason, answered)
		if not ok then answered(nil, tostring(err)) end
	end)
end

return {
	loadTandem = loadTandem,
	handoff = handoff,
}
