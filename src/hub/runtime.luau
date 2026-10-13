--!strict
-- The hub block's runtime record (`Block`, and the flight, replay and schedule records it holds) and what every hub
-- module does to the window through it: `draw` renders, and a render that raises means the window is gone, so `stop`
-- ends the block, its timers and its agent flight (returning the flight's worktree lease); frame ops after a render; the
-- arrival alerts a new board brings. The sample boards' fixtures and the text helpers the hub modules share live here too.
local Agent = require("../agent")
local AgentFix = require("./agent-fix")
local Github = require("../github")
local Host = require("../host")
local Log = require("../ci/log")
local Model = require("./model")
local Paths = require("../view/hub/paths")
local State = require("./state")
local Sync = require("./sync")

type State = State.State

export type Timers = { probe: TimerHandle?, refresh: TimerHandle?, checks: TimerHandle?, debounce: TimerHandle?, ring: TimerHandle? }

-- What the schedule reads, kept between ticks. Times are seconds since the epoch.
export type Sched = {
	probedAt: number?, probeChanged: boolean, -- the last probe, and whether it saw a change no refresh has covered
	focusedAt: number?, -- a focus (or the open) no refresh has covered
	checksAt: number?,
	refreshTried: number?, -- the last refresh attempt, kept on failure so a failed refresh never retries at once
	lastModified: string?, -- the probe's validator
}

-- Only Block holds an engine or a pending folder callback. The token survives synchronous
-- completion before AgentHost.startAgentFix returns its handle.
export type AgentFlight = {
	key: string, engine: AgentFix.Engine?, settled: boolean, stopping: boolean,
	input: AgentFix.Input?, bot: boolean?, cancel: (() -> ())?, releasing: boolean, starting: boolean?, fixtureStep: number?,
	failure: string?, -- why the engine failed: a lease held after it keeps this failed state, which a watched card would otherwise drop
}

-- A local edit (a pending merge, a dropped PR) the viewer made that no write has stored: the PR it named, the head it was
-- made on, and the edit itself, which can be applied again to another board. `at` is a time (seconds) by which that head
-- had been seen: a snapshot whose request began after it is the later word on the head (see `replayEdits`). `applied` is
-- whether the edit is on the board now, and `present` whether its PR is still on the board after it (a dropped PR is not),
-- which is what a write must hold to represent the edit (see `persist`). An edit made while its PR was absent from the board
-- (a capped cache omitted it) is kept unapplied until the PR returns on that head. Replays stay in the order the edits were made.
-- `queued` marks a pending merge in the repo's queue: GitHub reporting the queue dropped that PR retires it (see `replayEdits`).
export type Replay = { key: string, head: string, at: number, edit: () -> (), applied: boolean, present: boolean, queued: boolean? }

-- The hub block's own state.
export type Block = {
	s: State,
	cache: Sync.Cache?, -- what `hub.cache` last held (or this block last wrote)
	fixture: string?, -- `fixture=cases`: recorded data, no network, no timers
	generate: boolean, -- ⏎ opens the PR with the AI guide started
	agent: Agent.Agent?, -- the reader's own agent, once found (never with a fixture)
	agentFlight: AgentFlight?, -- lookup, engine and retained lease; never serialized
	botKeys: { [string]: boolean }, -- retains the bot input kind across clone/stop/retry, never saved
	github: Github.Client, timers: Timers,
	filterViewer: string?, filtersDirty: boolean?, -- account whose personal filters were loaded; edits made before its first refresh
	ci: { Log.Provider }, -- who reads a failing check's log: Buildkite, then GitHub Actions
	flights: { refresh: boolean, checks: boolean, probe: boolean, flake: boolean, tandem: boolean }, -- one call of each kind at a time
	watched: { [string]: boolean }, -- the PRs Tandem watches (lowercase "owner/repo#123"): the cache's flags until a read of Tandem succeeds, then that read
	handoffs: number, -- hand-offs Tandem has taken this session: a read that began before one cannot name that PR
	seen: { [string]: boolean }, -- write ids of caches this block stored or joined: one id is another window's word once, never again
	heard: { { string } }, -- the PRs each other window's ownership-bearing write joined since the read of Tandem now out began, by key
	held: string?, -- the write id of the stored cache this block's snapshot is: the one it last stored or adopted ("" when that had none; see `sharedCache`)
	replays: { Replay }, -- successful local edits no write has stored yet; `persist` clears those it stores, `adoptShared` lays them back onto an adopted cache
	retired: { [string]: boolean }, -- write ids of stored caches a successful read of Tandem superseded whose own save failed (see `retire`)
	unsaved: boolean, -- ownership restored onto an adopted cache that no write has stored yet (see `adoptShared`); `persist` clears it
	root: string?, -- the repository root `cx.cwd` is in, found once (Tandem's calls name the project by it)
	rootWaiters: { (string?) -> () }?, -- the callers waiting on that lookup while it runs
	sched: Sched,
	closed: boolean, -- a render failed: the window is gone, so no timer starts anything
	refetch: boolean, -- a refresh was asked for while one was running: run another when it ends
	show: Model.PRRef?, -- a pull request just added by link: select it when the refresh brings it
	records: { [string]: Sync.MergeRecord }, -- each repo's hub.merge.* record, read once
	detecting: { [string]: boolean }, -- repos whose merge method was asked for this session (once each, success or not)
	histories: Github.HistoryCache, -- each repo's base-branch run history, read once an hour (memory only: no kv key)
	flakeTried: { [string]: boolean }, -- cards (by key and head) whose evidence was read this session, success or not
	step: number, -- fixture only: how many `refreshes` entries ⌘R has applied
}

export type Handler = (b: Block, cx: BlockCx, value: string) -> ()

-- Fixtures by name, loaded only when asked for. `cases` is the rules' recorded pull requests.
local FIXTURES: { [string]: () -> any } = {
	cases = function() return require("../../fixtures/hub/cases") end,
	summary = function() return require("../../fixtures/hub/summary") end,
	rereview = function() return require("../../fixtures/hub/rereview") end,
	["agent-cards"] = function() return require("../../fixtures/hub/agent-cards") end,
	["review-fix"] = function() return require("../../fixtures/hub/review-fix") end,
}

-- Sends frame ops after the render that draws their targets. A target the render dropped makes the frame
-- fail, which leaves nothing to do.
local function frameLater(cx: BlockCx, ops: { any })
	Host.timer(1, function()
		pcall(function() cx:frame(ops) end)
	end)
end

local function revealSelected(b: Block, cx: BlockCx)
	local card = State.selectedCard(b.s)
	if card then return frameLater(cx, { { "reveal", Paths.card(card), "nearest" } }) end
	local recent = State.selectedRecent(b.s)
	if recent then frameLater(cx, { { "reveal", Paths.recentRow(State.ROW_FOLD[b.s.tab], State.recentKey(recent)), "nearest" } }) end
end

-- The reason alone from a "Couldn't …: reason" message; the board adds its own lead-in.
local function reasonOf(message: string): string
	return string.match(message, "^Couldn't [^:]*: (.*)$") or message
end

local function forgetReturned(b: Block, flight: AgentFlight): string
	local disposition
	if b.fixture then
		disposition = if flight.settled then "forget" else "wait"
	else
		local lease = if flight.engine then flight.engine.held() else nil
		-- The engine's held lease is the truth. A failure that reached the board before any worktree event, or before the
		-- engine handle existed, names no path, and a card Tandem owns drops such a state; put it back so the lease keeps
		-- its Return worktree until a guarded return succeeds.
		if lease and flight.settled and flight.failure and b.s.agents[flight.key] == nil then
			State.agentFailed(b.s, flight.key, flight.failure, lease.path, true)
		end
		disposition = State.agentFlight(b.s, flight.key, {
			settled = flight.settled, starting = flight.starting == true, releasing = flight.releasing,
			busy = flight.engine ~= nil and flight.engine.busy(), worktree = if lease then lease.path else nil,
		})
	end
	if disposition == "forget" and b.agentFlight == flight then b.agentFlight = nil end
	return disposition
end

-- Retry and close return through the same retained engine. A callback alone is not
-- proof of return: re-read held() before dropping the handle or allowing another run.
local function returnAgentLease(b: Block, flight: AgentFlight, done: (boolean?, string?) -> ())
	local engine = flight.engine
	if not engine or flight.releasing then return end
	flight.releasing = true
	local called = false
	local function returned(ok: boolean?, err: string?)
		if called then return end
		called = true
		flight.releasing = false
		local disposition = forgetReturned(b, flight)
		if disposition == "release" then ok, err = nil, err or "The worktree lease could not be returned" end
		done(ok, err)
	end
	local ok, err = pcall(engine.release, returned)
	if not ok then returned(nil, tostring(err)) end
end

local function closeAgentFlight(b: Block, flight: AgentFlight)
	local disposition = forgetReturned(b, flight)
	if disposition == "ready" then return end
	if not flight.settled then
		flight.stopping = true
		if flight.cancel then flight.cancel() end
		-- stop waits for any worker, then returns its lease.
		if flight.engine then flight.engine.stop() end
	elseif disposition == "release" then
		returnAgentLease(b, flight, function(ok, err)
			if not ok then
				local lease = (flight.engine :: AgentFix.Engine).held()
				State.agentFailed(b.s, flight.key, err or "The worktree lease could not be returned", if lease then lease.path else nil, lease ~= nil)
			end
		end)
	end
end

local function stop(b: Block)
	if b.closed then return end
	b.closed = true
	local flight = b.agentFlight
	State.closeAgent(b.s)
	if flight then closeAgentFlight(b, flight) end
	local timers = b.timers :: any
	for _, name in { "probe", "refresh", "checks", "debounce", "ring" } do
		local handle: TimerHandle? = timers[name]
		if handle then handle:cancel() end
		timers[name] = nil
	end
end

-- Renders; a render that raises means the block is gone.
local function draw(b: Block, cx: BlockCx)
	if b.closed then return end
	if not pcall(function() cx:render() end) then stop(b) end
end

-- How long an arrival's ring or wash is held before it fades, and how long the fade takes (--gp-dur-rare, plus a
-- little slack so the class outlives the transition).
local RING_HOLD_MS, RING_FADE_MS = 1400, 360

-- Alerts for one refresh: `fresh` against `old` (nil on a first load, which shows nothing). Sets the rings
-- and washes the next projection paints, shows the one toast, and starts the timers that fade and then end
-- the ring. The viewer's own actions (`s.acted`) are skipped and then forgotten. Call before `State.replace`.
local function announce(b: Block, cx: BlockCx, old: Sync.Cache?, fresh: { Model.HubPR }, now: number)
	local s = b.s
	local alerts = Sync.alerts(Sync.diff(old, fresh, now, s.acted, s.ignoredChecks))
	s.acted = {}
	if alerts.toast then cx:toast("error", alerts.toast.text, alerts.toast.sub) end
	if #alerts.rings + #alerts.good == 0 then return end
	s.ringed = {}
	for _, key in alerts.rings do s.ringed[key] = "bad" end
	for _, key in alerts.good do s.ringed[key] = "good" end
	-- A background refresh is not a key press: the arrival may animate.
	s.keyed = false
	local timers = b.timers :: any
	local running: TimerHandle? = timers.ring
	if running then running:cancel() end
	local function after(ms: number, fn: () -> ())
		timers.ring = Host.timer(ms, function()
			timers.ring = nil
			if b.closed then return end
			fn()
			State.project(b.s)
			draw(b, cx)
		end)
	end
	after(RING_HOLD_MS, function()
		for key, kind in b.s.ringed do b.s.ringed[key] = (kind .. "-out") :: any end
		after(RING_FADE_MS, function() b.s.ringed = {} end)
	end)
end

local function isoNow(): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", Host.time()) :: string
end

return {
	FIXTURES = FIXTURES,
	frameLater = frameLater,
	revealSelected = revealSelected,
	reasonOf = reasonOf,
	forgetReturned = forgetReturned,
	returnAgentLease = returnAgentLease,
	closeAgentFlight = closeAgentFlight,
	draw = draw,
	announce = announce,
	isoNow = isoNow,
}
