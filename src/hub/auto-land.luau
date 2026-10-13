--!strict
-- Auto-land's state machine and the registry of merge kinds it knows. From a PR's record, the board's PR and what the
-- auto-land read says, `step` gives the next record and the one effect hub/auto-land-run carries out: queue the merge,
-- recover (rebase or an empty commit), read, stop, or turn off. Also the kv codecs for the records and the settings.
-- Pure: no clock, no network. Callers pass `now` (seconds since the epoch) and `iso`, the same time as a string.
local Model = require("./model")

export type Phase = "waiting" | "queued" | "recovering" | "stopped"
export type Record = {
	key: string, id: string, -- the PR's board key and node id (the id lets the read ask about a PR the board dropped)
	phase: Phase,
	tries: number, -- recoveries made
	head: string, -- the head auto-land accepts as the branch's: the one it was turned on at, the viewer's own push, or one it made
	adopt: boolean, -- a rebase was sent and its new head is not known yet: the next new head is auto-land's own
	queuedAt: string?, -- when the merge was last asked for; only label events and replies after it count
	approved: boolean, -- the PR was approved while auto-land was on, so losing that approval stops it
	reason: string?, -- phase "stopped": why
	at: string, -- when the phase last changed (ISO)
	rev: number, -- bumped on every write, for the read-then-write guard
}
export type Settings = { tries: number, label: string } -- the try cap and the dequeue label

-- A write a step asks for; hub/auto-land-run turns each into a Github command. "merge" is Github.commands.merge with the
-- repo's method.
export type Op = { kind: "merge" } | { kind: "remove_label", label: string }
export type Signal = "queued" | "dequeued" | "cancelled"
-- One merge kind: how it queues, how a queued PR reads, and what an info toast says when a person cancelled it.
export type Kind = {
	needsFacts: boolean, -- queueing needs the auto-land read (labels) to decide its ops
	queue: (method: Model.MergeMethod, facts: Model.LandFacts?, settings: Settings) -> { Op }?, -- nil: can't decide yet
	signal: (record: Record, pr: Model.HubPR, facts: Model.LandFacts?, method: Model.MergeMethod, settings: Settings, now: number) -> Signal,
	cancelled: ((method: Model.MergeMethod) -> string)?, -- the notice for a "cancelled" signal; nil for a kind that never sends one
}

export type Effect =
	{ kind: "queue", ops: { Op } }
	| { kind: "recover" } -- the runner reads details and picks rebase or empty commit (M.recovery)
	| { kind: "read" } -- the step needs the auto-land read to decide; the runner reads it and steps again
	| { kind: "stopped", reason: string }
	| { kind: "off", notice: string? } -- the record is gone; `notice` is an info toast ("the merge-queue label was removed")
export type Context = { now: number, iso: string, viewer: string, method: Model.MergeMethod?, settings: Settings }

local M = {}

M.DEFAULTS = { tries = 5, label = "blocked" } :: Settings
M.MAX_TRIES = 20
-- A rebase whose new head never showed is given up on after this long, and the next step decides again.
M.RECOVER_SECONDS = 600
-- A bot that removes the merge label without adding the dequeue label (Aviator set up without one) has dequeued the PR
-- once this long has passed with the label still off.
M.LABEL_GRACE = 600

local OFF: Effect = { kind = "off", notice = nil }
local READ: Effect = { kind = "read" }

local function has(list: { string }, name: string): boolean
	return table.find(list, name) ~= nil
end

-- The newest event that added (or removed) `label`.
local function latest(events: { Model.LabelEvent }, label: string, added: boolean): Model.LabelEvent?
	local found: Model.LabelEvent? = nil
	for _, event in events do
		if event.label == label and event.added == added and (found == nil or event.at >= found.at) then found = event end
	end
	return found
end

local MERGE: { Op } = { { kind = "merge" } }

local label: Kind = {
	needsFacts = true,
	queue = function(_method: Model.MergeMethod, facts: Model.LandFacts?, settings: Settings): { Op }?
		if facts == nil then return nil end
		if not has(facts.labels, settings.label) then return MERGE end
		local remove: Op = { kind = "remove_label", label = settings.label }
		return { remove, MERGE[1] }
	end,
	signal = function(record: Record, _pr: Model.HubPR, facts: Model.LandFacts?, method: Model.MergeMethod, settings: Settings, now: number): Signal
		if facts == nil or method.kind ~= "label" then return "queued" end
		if has(facts.labels, method.label) then return "queued" end
		local since = record.queuedAt or ""
		if has(facts.labels, settings.label) then
			local added = latest(facts.events, settings.label, true)
			if added == nil or added.at >= since then return "dequeued" end
		end
		local removed = latest(facts.events, method.label, false)
		if removed == nil or removed.at < since then return "queued" end
		if not removed.bot then return "cancelled" end
		local at = Model.epoch(removed.at)
		if at and now - at >= M.LABEL_GRACE then return "dequeued" end
		return "queued"
	end,
	cancelled = function(method: Model.MergeMethod): string
		return "the " .. (if method.kind == "label" then method.label else "merge") .. " label was removed"
	end,
}

local comment: Kind = {
	needsFacts = false,
	queue = function(): { Op }? return MERGE end,
	signal = function(_record: Record, pr: Model.HubPR): Signal
		return if pr.mergeFailure then "dequeued" else "queued"
	end,
	cancelled = nil,
}

local queue: Kind = {
	needsFacts = false,
	queue = function(): { Op }? return MERGE end,
	signal = function(_record: Record, pr: Model.HubPR, facts: Model.LandFacts?): Signal
		if pr.mergeFailure and pr.mergeFailure.kind == "queue" then return "dequeued" end
		if facts and not facts.autoMerge then return "cancelled" end
		return "queued"
	end,
	cancelled = function(): string return "auto-merge was turned off" end,
}

M.KINDS = { label = label, comment = comment, queue = queue } :: { [string]: Kind }

-- A resolved, confirmed method whose kind auto-land knows.
function M.supports(resolution: Model.MergeResolution?): boolean
	return resolution ~= nil and not resolution.ask and M.KINDS[resolution.method.kind] ~= nil
end

function M.start(pr: Model.HubPR, iso: string): Record
	return {
		key = pr.key, id = pr.id, phase = "waiting", tries = 0, head = pr.headOid, adopt = false, queuedAt = nil,
		approved = false, reason = nil, at = iso, rev = 1,
	}
end

function M.mark(record: Record?): Model.LandMark?
	if record == nil then return nil end
	if record.phase == "stopped" then return { state = "stopped", reason = record.reason or "" } end
	return { state = "on", tries = record.tries }
end

-- A copy of `record` for the next write.
local function bump(record: Record): Record
	local out = table.clone(record)
	out.rev = record.rev + 1
	return out
end

function M.stop(record: Record, reason: string, iso: string): Record
	local out = bump(record)
	out.phase, out.reason, out.at, out.adopt = "stopped", reason, iso, false
	return out
end

local function stopped(record: Record, reason: string, iso: string): (Record?, Effect?)
	return M.stop(record, reason, iso), { kind = "stopped", reason = reason }
end

local function recover(record: Record, ctx: Context): (Record?, Effect?)
	if record.tries >= ctx.settings.tries then return stopped(record, "Tried " .. record.tries .. " times", ctx.iso) end
	local out = bump(record)
	out.tries, out.phase, out.adopt, out.at = record.tries + 1, "recovering", false, ctx.iso
	return out, { kind = "recover" }
end

-- The branch is at `head` and auto-land takes it as its own: it waits on the checks there before queueing again.
local function accept(record: Record, head: string, iso: string): Record
	local out = bump(record)
	out.head, out.adopt, out.phase, out.queuedAt, out.at = head, false, "waiting", nil, iso
	return out
end

-- The next record and the effect to carry out. A step that changes nothing returns the same record and no effect; a nil
-- record means auto-land is off for the PR.
function M.step(record: Record, pr: Model.HubPR?, facts: Model.LandFacts?, ctx: Context): (Record?, Effect?)
	if facts and (facts.state == "closed" or facts.state == "merged") then return nil, OFF end
	if record.phase == "stopped" then
		-- The viewer pushed after the stop: they have taken the branch back.
		if pr and pr.headOid ~= record.head then return nil, OFF end
		return record, nil
	end
	if pr == nil then return record, nil end
	if pr.draft then return nil, OFF end
	if pr.tandem then return nil, { kind = "off", notice = "Tandem watches it" } end
	local method = ctx.method
	if method == nil or M.KINDS[method.kind] == nil then return stopped(record, "The merge method changed", ctx.iso) end
	local kind = M.KINDS[method.kind]

	if pr.headOid ~= record.head then
		if record.adopt then
			record = accept(record, pr.headOid, ctx.iso)
		elseif facts and facts.headOid == pr.headOid then
			local author = facts.headAuthor
			if author == nil or string.lower(author) ~= string.lower(ctx.viewer) then
				return stopped(record, if author then "New commits from @" .. author else "New commits from someone else", ctx.iso)
			end
			record = accept(record, pr.headOid, ctx.iso)
		else
			return record, READ
		end
	end

	if pr.conflicts then return stopped(record, "Merge conflict", ctx.iso) end
	local decision = pr.reviews.decision
	if decision == "changes_requested" then return stopped(record, "Changes requested", ctx.iso) end
	if record.approved and decision == "review_required" then return stopped(record, "Approval dismissed", ctx.iso) end
	if decision == "approved" and not record.approved then
		record = bump(record)
		record.approved = true
	end
	-- A repo that requires no review ("none") is approved for queueing and never stops on it.
	local approved = decision == "approved" or decision == "none"

	if record.phase == "recovering" then
		local at = Model.epoch(record.at)
		if at == nil or ctx.now - at < M.RECOVER_SECONDS then return record, nil end
		local out = bump(record)
		out.adopt, out.phase, out.at = false, "waiting", ctx.iso
		return out, nil
	end

	if record.phase == "waiting" then
		local checks = pr.checks.state
		if checks == "failing" then return recover(record, ctx) end
		if checks == "pending" or not approved then return record, nil end
		local ops = kind.queue(method, facts, ctx.settings)
		if ops == nil then return record, if kind.needsFacts and facts == nil then READ else nil end
		local out = bump(record)
		out.phase, out.queuedAt, out.at = "queued", ctx.iso, ctx.iso
		return out, { kind = "queue", ops = ops }
	end

	local signal = kind.signal(record, pr, facts, method, ctx.settings, ctx.now)
	if signal == "dequeued" then return recover(record, ctx) end
	if signal == "cancelled" then return nil, { kind = "off", notice = if kind.cancelled then kind.cancelled(method) else nil } end
	return record, nil
end

-- How to make the checks run again: catch up with the base when behind it, else an empty commit. Nil when it can't be
-- told (no behind count) or nothing safe would help (a conflict).
function M.recovery(behindBy: number?, conflicts: boolean): ("rebase" | "empty")?
	if conflicts or behindBy == nil then return nil end
	return if behindBy > 0 then "rebase" else "empty"
end

-- The record after a recovery went through: a rebase's head is not known yet, so the next new head is adopted; an empty
-- commit's head is `sha`, and auto-land waits on its checks.
function M.recovered(record: Record, how: "rebase" | "empty", sha: string?, iso: string): Record
	local out = bump(record)
	out.at = iso
	if how == "rebase" then
		out.adopt = true
	else
		out.head, out.adopt, out.phase, out.queuedAt = sha or record.head, false, "waiting", nil
	end
	return out
end

-- "Auto-land", "Auto-land · try 2 of 5", or "Auto-land stopped".
function M.label(mark: Model.LandMark, cap: number): string
	if mark.state == "stopped" then return "Auto-land stopped" end
	if mark.tries == 0 then return "Auto-land" end
	return "Auto-land · try " .. mark.tries .. " of " .. math.max(cap, mark.tries)
end

-- kv codecs -----------------------------------------------------------------------------------------------------
-- `hub.autoland` = { schema = 1, prs = { [key] = Record } }; `hub.autoland.settings` = { tries, label }. A malformed
-- store never throws: a bad record is left out, a bad document is no records.

local PHASES: { [string]: boolean } = { waiting = true, queued = true, recovering = true, stopped = true }

local function isCount(value: any): boolean
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function optionalString(value: any): boolean
	return value == nil or type(value) == "string"
end

local function loadRecord(key: any, raw: any): Record?
	if type(key) ~= "string" or type(raw) ~= "table" or raw.key ~= key then return nil end
	if type(raw.id) ~= "string" or type(raw.head) ~= "string" or type(raw.at) ~= "string" then return nil end
	if type(raw.phase) ~= "string" or not PHASES[raw.phase] or not isCount(raw.tries) or not isCount(raw.rev) then return nil end
	if type(raw.adopt) ~= "boolean" or type(raw.approved) ~= "boolean" then return nil end
	if not optionalString(raw.queuedAt) or not optionalString(raw.reason) then return nil end
	if raw.phase == "stopped" and type(raw.reason) ~= "string" then return nil end
	return {
		key = key, id = raw.id, phase = raw.phase, tries = raw.tries, head = raw.head, adopt = raw.adopt,
		queuedAt = raw.queuedAt, approved = raw.approved, reason = raw.reason, at = raw.at, rev = raw.rev,
	}
end

function M.loadRecords(raw: any): { [string]: Record }
	local out: { [string]: Record } = {}
	if type(raw) ~= "table" or raw.schema ~= 1 or type(raw.prs) ~= "table" then return out end
	for key, value in raw.prs do
		local record = loadRecord(key, value)
		if record then out[record.key] = record end
	end
	return out
end

function M.saveRecords(records: { [string]: Record }): any
	local prs: { [string]: Record } = {}
	for key, record in records do prs[key] = table.clone(record) end
	return { schema = 1, prs = prs }
end

function M.loadSettings(raw: any): Settings
	local tries, label = M.DEFAULTS.tries, M.DEFAULTS.label
	if type(raw) == "table" then
		if type(raw.tries) == "number" and raw.tries == raw.tries then tries = math.clamp(math.floor(raw.tries), 1, M.MAX_TRIES) end
		if type(raw.label) == "string" then
			local trimmed = string.match(raw.label, "^%s*(.-)%s*$") :: string
			if trimmed ~= "" then label = trimmed end
		end
	end
	return { tries = tries, label = label }
end

return M
