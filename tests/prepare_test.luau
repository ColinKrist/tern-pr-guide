--!strict
-- Background guides: which PRs want one (review requests of the viewer whose guide is missing or for another head), one
-- explained at a time, never the review, a failure not retried at that head, a stop when Settings turn it off or the
-- block closes, and another window's live lease respected. Fetch, Prdata and AgentHost are replaced by recorders.
local AgentHost: any = require("../src/agent-host")
local Fetch: any = require("../src/fetch")
local Host: any = require("../src/host")
local Prdata: any = require("../src/prdata")
local Prepare = require("../src/hub/prepare")

local function pr(key: string, head: string, requested: boolean): any
	local repo, number = string.match(key, "^(.-)#(%d+)$")
	return { key = key, repo = repo, number = tonumber(number), headOid = head, reviews = { requestedMe = requested } }
end

type World = {
	b: any, explained: { string }, opened: { string }, kv: { [string]: any }, guides: { [string]: string },
	settle: (ok: boolean) -> (),
}

local function world(prs: { any }): World
	local w: World = { b = nil, explained = {}, opened = {}, kv = {}, guides = {}, settle = function() end }
	local waiting: { (any, string?) -> () } = {}
	Fetch.checkoutFor = function(_near, _dir, slug: string, done) done({ root = "/c/" .. slug, guides = "/c/" .. slug .. "/.git/prguide" }) end
	Fetch.savedCopy = function() return nil, "none" end
	Fetch.guideHead = function(repo, number: number): string? return w.guides[repo.root .. "#" .. number] end
	Prdata.openPr = function(target, _progress, done)
		table.insert(w.opened, target.repo .. "#" .. target.pr)
		done({ number = tonumber(target.pr), head = "loaded" }, nil)
	end
	AgentHost.explain = function(_agent, repo, loaded, done)
		table.insert(w.explained, repo.root .. "#" .. loaded.number)
		table.insert(waiting, done)
	end
	AgentHost.draftReview = function() error("a background guide never drafts a review") end
	Host.kv = {
		get = function(key: string): any return w.kv[key] end,
		set = function(key: string, value: any) w.kv[key] = value end,
	}
	Host.time = function(): number return 1000 end
	Host.getenv = function(): string? return "/home" end
	w.settle = function(ok: boolean)
		local done = table.remove(waiting, 1) :: any
		if ok then done({}, nil) else done(nil, "it timed out") end
	end
	w.b = { fixture = nil, closed = false, agent = { command = "/omp" }, s = { prs = prs, prepareGuides = true } }
	return w
end

local function pure()
	local prs = { pr("acme/api#1", "h1", true), pr("acme/api#2", "h2", false), pr("acme/web#3", "h3", true) }
	local function keys(list: { any }): string
		local out = {}
		for _, p in list do table.insert(out, p.key) end
		return table.concat(out, ",")
	end
	assert(keys(Prepare.candidates(prs, {})) == "acme/api#1,acme/web#3", "only review requests of the viewer")
	assert(keys(Prepare.candidates(prs, { ["acme/api#1@h1"] = true })) == "acme/web#3", "a PR tried at its head is left out")
	assert(keys(Prepare.candidates(prs, { ["acme/api#1@old"] = true })) == "acme/api#1,acme/web#3", "a new head is tried again")
	local one = prs[1]
	assert(Prepare.needsGuide(nil, one), "no guide")
	assert(Prepare.needsGuide("old", one), "a guide for another head")
	assert(Prepare.needsGuide("", one), "a guide that names no head")
	assert(not Prepare.needsGuide("h1", one), "a guide for this head")
end

local cx: any = { cwd = "/work" }

local function flow()
	-- One at a time, only what needs a guide, explanation only.
	local w = world({ pr("acme/api#1", "h1", true), pr("acme/api#2", "h2", true), pr("acme/api#3", "h3", true), pr("acme/api#4", "h4", false) })
	w.guides["/c/acme/api#2"] = "h2"
	w.guides["/c/acme/api#3"] = "old"
	Prepare.run(w.b, cx)
	assert(table.concat(w.explained, ",") == "/c/acme/api#1", "the first PR alone: " .. table.concat(w.explained, ","))
	assert(w.kv["hub.preparing"] and w.kv["hub.preparing"].key == "acme/api#1@h1", "it holds the lease")
	Prepare.run(w.b, cx)
	assert(#w.explained == 1, "a refresh while one runs starts nothing")
	w.settle(true)
	assert(table.concat(w.explained, ",") == "/c/acme/api#1,/c/acme/api#3", "then the stale one; the current guide and #4 are left: " .. table.concat(w.explained, ","))
	assert(w.kv["hub.preparing"].key == "acme/api#3@h3", "the lease moves to it")
	w.settle(false)
	assert(#w.explained == 2, "nothing after the last")
	assert(w.kv["hub.preparing"] == nil, "the lease is returned, after a failure too")

	-- A failure isn't retried at that head; a new head is.
	Prepare.run(w.b, cx)
	assert(#w.explained == 2, "tried PRs aren't explained again this session")
	w.b.s.prs[3] = pr("acme/api#3", "h3b", true)
	Prepare.run(w.b, cx)
	assert(w.explained[3] == "/c/acme/api#3", "a new head is prepared")
	w.settle(true)

	-- Settings turned off mid-run: the PR running finishes, nothing more starts.
	w = world({ pr("acme/api#1", "h1", true), pr("acme/api#2", "h2", true) })
	Prepare.run(w.b, cx)
	w.b.s.prepareGuides = false
	w.settle(true)
	assert(#w.explained == 1, "turned off, it stops")
	Prepare.run(w.b, cx)
	assert(#w.explained == 1, "and doesn't start while off")

	-- A closed block stops too.
	w = world({ pr("acme/api#1", "h1", true), pr("acme/api#2", "h2", true) })
	Prepare.run(w.b, cx)
	w.b.closed = true
	w.settle(true)
	assert(#w.explained == 1, "a closed block stops")

	-- Another window's live lease on a PR: this window passes it by.
	w = world({ pr("acme/api#1", "h1", true), pr("acme/api#2", "h2", true) })
	w.kv["hub.preparing"] = { key = "acme/api#1@h1", at = 900 }
	Prepare.run(w.b, cx)
	assert(table.concat(w.explained, ",") == "/c/acme/api#2", "a PR another window prepares is skipped: " .. table.concat(w.explained, ","))
	w.settle(true)
	-- A lease left by a window that closed long ago doesn't hold.
	w = world({ pr("acme/api#1", "h1", true) })
	w.kv["hub.preparing"] = { key = "acme/api#1@h1", at = -5000 }
	Prepare.run(w.b, cx)
	assert(#w.explained == 1, "a stale lease is taken over")
	w.settle(true)

	-- Off by default, never on a sample board, never without an agent.
	w = world({ pr("acme/api#1", "h1", true) })
	w.b.s.prepareGuides = false
	Prepare.run(w.b, cx)
	w.b.s.prepareGuides, w.b.fixture = true, "cases"
	Prepare.run(w.b, cx)
	w.b.fixture, w.b.agent = nil, nil
	Prepare.run(w.b, cx)
	assert(#w.explained == 0 and #w.opened == 0, "nothing runs off, on a sample, or with no agent")
end

-- ⇧G in Settings toggles it while the search field is empty, as a click on the box does; plain g types
-- into the search, and ⇧G elsewhere is not this.
local function key()
	local Agent = require("../src/agent")
	local Fields = require("../src/text-field")
	local Keys = require("../src/keys")
	local State = require("../src/hub/state")
	local s = State.new({}, 0, nil)
	assert(s.prepareGuides == false, "off by default")
	s.agent = Agent.new("", "", Agent.picks(nil, { review = { model = "a/b" } }) :: Agent.Picks)
	State.openMenu(s, "settings")
	assert(s.models, "Settings shows the model menu")
	local shiftG = { name = "g", shift = true, meta = false, ctrl = false, alt = false } :: any
	local action = Keys.hubAction(s, shiftG)
	assert(action and action.act == "hub-guides" and action.value == nil, "⇧G in Settings toggles background guides")
	State.setPrepareGuides(s, action.value)
	assert(s.prepareGuides == true)
	State.setPrepareGuides(s, "false")
	assert(s.prepareGuides == false, "a click names the side")
	local g = Keys.hubAction(s, { name = "g", text = "g", shift = false, meta = false, ctrl = false, alt = false } :: any)
	assert(not g or g.act ~= "hub-guides", "plain g types, so a search can start with gpt")
	s.models.field = Fields.create("gpt")
	local typed = Keys.hubAction(s, shiftG)
	assert(not typed or typed.act ~= "hub-guides", "⇧G types once the search has text")
	State.closeMenu(s)
	local board = Keys.hubAction(s, shiftG)
	assert(not board or board.act ~= "hub-guides", "⇧G on the board is something else")
end

return function()
	local saved = {
		fetch = { checkoutFor = Fetch.checkoutFor, savedCopy = Fetch.savedCopy, guideHead = Fetch.guideHead },
		prdata = { openPr = Prdata.openPr },
		agentHost = { explain = AgentHost.explain, draftReview = AgentHost.draftReview },
		host = { kv = Host.kv, time = Host.time, getenv = Host.getenv },
	}
	local ok, err = pcall(function()
		pure()
		flow()
		key()
	end)
	for name, fn in saved.fetch do Fetch[name] = fn end
	for name, fn in saved.prdata do Prdata[name] = fn end
	for name, fn in saved.agentHost do AgentHost[name] = fn end
	for name, value in saved.host do Host[name] = value end
	if not ok then error(err, 0) end
end
