--!strict
-- What a pull request offers to do on GitHub, under one set of rules for the hub's board and its review pages: which of
-- merge, merge when ready, cancel merge, update branch, re-request review and close a PR offers, why an offered one
-- can't run now, the question one asks before it runs, and the command it sends through the GitHub client it is given.
-- It reads no state, draws nothing, toasts nothing and touches no kv: hub/ops does the board's side of each.
local Github = require("./github")
local Model = require("./hub/model")

type HubPR = Model.HubPR
type MergeMethod = Model.MergeMethod

export type Id = "merge" | "force-merge" | "auto-merge" | "cancel-merge" | "update" | "rerequest" | "close"

-- What the rules read beyond the pull request itself.
export type Ctx = {
	column: Model.Column, -- where the board places the PR
	merge: Model.MergeResolution?, -- how the repo merges; nil = not known yet, and merge never guesses
	autoMerge: boolean?, -- the repo allows auto-merge; nil until detection has read it
	tandem: boolean, -- Tandem owns the branch
	readable: boolean, -- the ownership store could be read
	agent: boolean, -- an agent fix is at work on the branch
	behind: boolean, -- the base has commits the head lacks
}

export type Action = {
	id: Id,
	label: string,
	key: string, -- the key a selected card answers to
	what: (pr: HubPR) -> string, -- completes "Couldn't …: reason"
	offered: (pr: HubPR, ctx: Ctx) -> boolean, -- the PR lists it
	refusal: (pr: HubPR, ctx: Ctx) -> string?, -- why an offered action can't run now; asked again just before it runs
	question: (pr: HubPR, ctx: Ctx) -> string?, -- asked inline first; nil runs at once
	progress: (pr: HubPR, ctx: Ctx) -> string, -- the PR's busy mark while it runs
	run: (pr: HubPR, ctx: Ctx, github: Github.Client, done: (err: string?) -> ()) -> (),
}

local M = {}

M.UNCHECKED = "Tandem's ownership couldn't be checked"
M.TANDEM_OWNS = "Tandem watches this pull request"

local SQUASH: MergeMethod = { kind = "squash" }
local MERGE_LABELS: { [string]: string } = { squash = "Squash and merge", merge = "Create a merge commit", rebase = "Rebase and merge" }
local MERGE_BUSY: { [string]: string } = { comment = "Commenting…", label = "Adding label…", queue = "Queuing…" }

-- The repo's method, squash until its record is known.
function M.method(ctx: Ctx): MergeMethod
	return if ctx.merge then ctx.merge.method else SQUASH
end

-- Whether merging with `method` happens at once on GitHub, rather than being handed to the repo's queue, bot or label.
function M.immediate(method: MergeMethod): boolean
	return MERGE_LABELS[method.kind] ~= nil
end

-- One owner per branch: nothing new reaches a branch Tandem owns, or one whose ownership couldn't be checked.
local function owned(_: HubPR, ctx: Ctx): string?
	if not ctx.readable then return M.UNCHECKED end
	if ctx.tandem then return M.TANDEM_OWNS end
	return nil
end

local function none(): string?
	return nil
end

local function send(command: Github.Command, github: Github.Client, done: (err: string?) -> ())
	github.run(command, function(_, err)
		done(if err then err.message else nil)
	end)
end

-- The method a pending merge is taken back with: the queue's own, else the repo's. Nil when there is none.
local function cancelCommand(pr: HubPR, ctx: Ctx): Github.Command?
	local pending = pr.pending
	if not pending then return nil end
	local method = if pending.method == "queue" then { kind = "queue" } :: MergeMethod else M.method(ctx)
	local ok, command = pcall(Github.commands.cancelMerge, pr, method)
	if not ok or method.kind ~= pending.method then return nil end
	return command
end

local LIST: { Action } = {
	{
		id = "merge", label = "Merge", key = "M",
		what = function(pr) return "merge #" .. pr.number end,
		offered = function(pr, ctx) return ctx.column == "ready" and pr.pending == nil and not pr.behind end,
		refusal = function(pr, ctx)
			local why = owned(pr, ctx)
			if why then return why end
			if ctx.merge == nil then return "how " .. pr.repo .. " merges isn't known yet" end
			return nil
		end,
		-- A GitHub method can't be taken back, so it asks; a method the repo or the viewer chose (a queue, comment or
		-- label) runs at once, since it can be cancelled. A comment learned from the repo's history asks once.
		question = function(pr, ctx)
			local method = M.method(ctx)
			if ctx.merge and ctx.merge.ask and method.kind == "comment" then
				return "Comment " .. method.command .. ", as this repository usually does?"
			end
			local label = MERGE_LABELS[method.kind]
			return if label then label .. " #" .. pr.number .. "?" else nil
		end,
		progress = function(_, ctx) return MERGE_BUSY[M.method(ctx).kind] or "Merging…" end,
		run = function(pr, ctx, github, done) send(Github.commands.merge(pr, M.method(ctx)), github, done) end,
	},
	{
		id = "force-merge", label = "Force merge", key = "M",
		what = function(pr) return "force-merge #" .. pr.number end,
		offered = function(pr, ctx)
			local normal = ctx.column == "ready" and pr.pending == nil and not pr.behind
			return pr.role == "mine" and pr.pending == nil and not pr.conflicts and not pr.draft and not ctx.tandem
				and ctx.merge ~= nil and M.immediate(M.method(ctx)) and not normal
		end,
		refusal = owned,
		question = function(pr) return "Force-merge #" .. pr.number .. "? It is not ready." end,
		progress = function() return "Force-merging…" end,
		run = function(pr, ctx, github, done) send(Github.commands.merge(pr, M.method(ctx)), github, done) end,
	},
	{
		id = "auto-merge", label = "Merge when ready", key = "M",
		what = function(pr) return "set #" .. pr.number .. " to merge when ready" end,
		-- Tandem owns the branch: no new merge is offered. Auto-land asks for its own merge.
		offered = function(pr, ctx)
			return ctx.column == "in_review" and pr.pending == nil and not ctx.tandem
				and not (pr.autoLand ~= nil and pr.autoLand.state == "on") and Model.canMergeWhenReady(ctx.merge, ctx.autoMerge)
		end,
		refusal = owned,
		question = none,
		progress = function(_, ctx) return MERGE_BUSY[M.method(ctx).kind] or "Setting…" end,
		run = function(pr, ctx, github, done) send(Github.commands.autoMerge(pr, M.method(ctx)), github, done) end,
	},
	{
		id = "cancel-merge", label = "Cancel merge", key = "M",
		what = function(pr) return "cancel the merge of #" .. pr.number end,
		-- A merge already pending is only taken back, so Tandem's ownership doesn't stop it. A comment method with no
		-- cancel command can't take it back.
		offered = function(pr, ctx)
			local method = if ctx.merge then ctx.merge.method else nil
			return pr.pending ~= nil and (ctx.column == "in_review" or ctx.column == "ready")
				and not (method ~= nil and method.kind == "comment" and not method.cancel)
		end,
		refusal = function(pr, ctx)
			return if cancelCommand(pr, ctx) then nil else pr.repo .. " has no way to cancel it"
		end,
		question = none,
		progress = function() return "Cancelling…" end,
		run = function(pr, ctx, github, done) send(cancelCommand(pr, ctx) :: Github.Command, github, done) end,
	},
	{
		id = "update", label = "Update branch", key = "U",
		what = function(pr) return "update #" .. pr.number end,
		offered = function(pr, ctx) return pr.pending == nil and not pr.conflicts and ctx.behind end,
		refusal = owned,
		question = none,
		progress = function() return "Updating…" end,
		run = function(pr, _, github, done) send(Github.commands.updateBranch(pr), github, done) end,
	},
	{
		id = "rerequest", label = "Re-request review", key = "Q",
		what = function(pr) return "re-request review on #" .. pr.number end,
		offered = function(pr, ctx)
			local again = Model.awaitingReReview(pr)
			return ctx.column == "in_review" and again ~= nil and #again.ask > 0
		end,
		refusal = none,
		question = none,
		progress = function() return "Requesting…" end,
		run = function(pr, _, github, done)
			local again = Model.awaitingReReview(pr)
			send(Github.commands.requestReview(pr, table.concat(if again then again.ask else {}, ",")), github, done)
		end,
	},
	{
		id = "close", label = "Close pull request", key = "X",
		what = function(pr) return "close #" .. pr.number end,
		-- The viewer's own PRs, except while a merge or an agent is at work on one, or Tandem owns it.
		offered = function(pr, ctx) return pr.role == "mine" and pr.pending == nil and not ctx.agent and not ctx.tandem end,
		refusal = none,
		question = function(pr) return "Close #" .. pr.number .. "?" end,
		progress = function() return "Closing…" end,
		run = function(pr, _, github, done) send(Github.commands.close(pr), github, done) end,
	},
}

local BY_ID: { [string]: Action } = {}
for _, action in LIST do BY_ID[action.id] = action end

function M.get(id: Id): Action
	return BY_ID[id]
end

-- Whether `pr` offers action `id`.
function M.offers(pr: HubPR, ctx: Ctx, id: Id): boolean
	return BY_ID[id].offered(pr, ctx)
end

-- The actions `pr` offers, in menu order.
function M.list(pr: HubPR, ctx: Ctx): { Action }
	local out: { Action } = {}
	for _, action in LIST do
		if action.offered(pr, ctx) then table.insert(out, action) end
	end
	return out
end

return M
