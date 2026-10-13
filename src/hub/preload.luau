--!strict
-- Loads the board's pull requests in the background after a refresh, so a click on a card shows its diff at once: each
-- card that opens the review page, in board order, one at a time, from a checkout of its repo or PR Guide's copy of it
-- once that copy is set up (never a first download). Prdata keeps what loads and skips a PR already loaded at its head.
local Fetch = require("../fetch")
local Host = require("../host")
local Prdata = require("../prdata")
local Runtime = require("./runtime")
local State = require("./state")

type Block = Runtime.Block

-- The most cards loaded per pass.
local CARDS = 6

-- One block's preloading: whether a pass runs, whether a refresh asked for another meanwhile, and each repo's checkout
-- once looked for (false: none).
type Run = { running: boolean, again: boolean, checkouts: { [string]: Fetch.Repo | false } }

local runs: { [Block]: Run } = setmetatable({}, { __mode = "k" }) :: any

local M = {}

-- The cards a pass loads: the board's, in order, that open the review page rather than the fixes page.
function M.candidates(s: State.State): { State.Card }
	local out = {}
	for _, column in s.board.columns do
		for _, card in column.cards do
			if #out >= CARDS then return out end
			local fixes = card.column == "needs_fixes" or (card.agent ~= nil and card.agent.kind == "ready")
			if not fixes then table.insert(out, card) end
		end
	end
	return out
end

local function checkout(run: Run, cx: BlockCx, slug: string, done: (Fetch.Repo?) -> ())
	local known = run.checkouts[slug]
	if known ~= nil then return done(if known then known else nil) end
	Fetch.checkoutFor(nil, cx.cwd or Host.getenv("HOME") or "", slug, function(found)
		local repo = found or Fetch.readySavedCopy(slug)
		run.checkouts[slug] = repo or false
		done(repo)
	end)
end

local function pass(b: Block, cx: BlockCx, run: Run, queue: { State.Card }, i: number)
	local card = queue[i]
	if not card or b.closed then
		run.running = false
		if run.again and not b.closed then M.run(b, cx) end
		return
	end
	local pr = card.pr
	checkout(run, cx, pr.repo, function(repo)
		if not repo or b.closed then return pass(b, cx, run, queue, i + 1) end
		local target = { pr = tostring(pr.number), repo = repo.root, cache = repo.cache, head = pr.headOid, base = pr.baseBranch }
		Prdata.openPr(target, function() end, function()
			pass(b, cx, run, queue, i + 1)
		end)
	end)
end

-- Starts a pass over the board, or, while one runs, asks for another once it ends.
function M.run(b: Block, cx: BlockCx)
	if b.fixture or b.closed then return end
	local run = runs[b]
	if not run then
		run = { running = false, again = false, checkouts = {} }
		runs[b] = run
	end
	if run.running then
		run.again = true
		return
	end
	run.running, run.again = true, false
	pass(b, cx, run, M.candidates(b.s), 1)
end

return M
