--!strict
-- Saved visibility and check rules, their keyboard flow, and named-check evidence boundaries.
local Block: any = require("../src/hub/block")
local FilterStore = require("../src/hub/filter-store")
local Ui: any = require("../src/view/ui")
local Paths = require("../src/view/hub/paths")
local CheckFilter = require("../src/hub/check-filter")
local Fields = require("../src/text-field")
local Github = require("../src/github")
local Host: any = require("../src/host")
local Keys = require("../src/keys")
local Ops = require("../src/hub/ops")
local Model = require("../src/hub/model")
local State = require("../src/hub/state")
local Sync = require("../src/hub/sync")
local Cases: any = require("../fixtures/hub/cases")

local function copy(value: any): any
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in value do out[k] = copy(v) end
	return out
end

local function pr(number: number, title: string, names: { string }): Model.HubPR
	local p = copy(Cases.prs[1])
	p.key, p.id, p.repo, p.number, p.title = "acme/api#" .. number, "PR" .. number, "acme/api", number, title
	p.headOid, p.lastActivityAt, p.role, p.draft, p.tandem = "head" .. number, Cases.asOfIso, "mine", false, false
	p.conflicts, p.behind, p.mergeFailure, p.pending = false, false, nil, nil
	p.reviews.decision, p.reviews.latest, p.reviews.threads, p.reviews.comments, p.reviews.unresolved = "review_required", {}, {}, 0, 0
	p.checks = { state = "failing", passing = 2, failing = #names, pending = 0, failedNames = names }
	return p
end

return function()
	local automatic = pr(1, "[Agent] Skip unit tests", { "Unit tests" })
	local personal = pr(2, "Fix checkout", { "Unit tests" })
	local approval = pr(3, "Improve docs", { "PR approval" })
	local s = State.new({ automatic, personal, approval }, Cases.asOf, nil)
	assert(s.board.counts.mine == 3)
	State.openMenu(s, "filters")
	State.menuPick(s, 2)
	assert(s.menu == "title-filter" and s.filterEdit and s.filterEdit.typing)
	assert(Keys.hubAction(s, { name = "j", text = "j" } :: any) == nil, "letters type while editing")
	assert(not State.saveFilter(s), "empty rules are never applied")
	local titleEdit = s.filterEdit :: State.FilterEdit
	titleEdit.field = Fields.create("[agent]")
	assert(State.saveFilter(s) and s.menu == "filters")
	assert(s.board.counts.mine == 2 and s.board.hidden == 1 and s.board.nextUp and s.board.nextUp.total == 2)
	for _ = 1, 3 do assert(State.walk(s) and s.selected ~= automatic.key) end
	State.openMenu(s, "filters")
	State.toggleFilter(s, 2)
	assert(not s.titleRules[1].enabled and s.board.counts.mine == 3 and s.titleRules[1].value == "[agent]")
	State.toggleFilter(s, 2)
	assert(s.board.counts.mine == 2)
	-- Repository is one saved rule even with multiple selections; pause retains the selection.
	State.toggleRepository(s, "other/repo")
	assert(s.board.nextUp == nil and s.board.counts.mine == 0)
	State.toggleFilter(s, 1)
	assert(s.repositories and s.repositories["other/repo"] and s.board.counts.mine == 2)
	local back = State.new(copy(s.prs), Cases.asOf, State.saved(s))
	assert(not back.repositoriesEnabled and back.titleRules[1].enabled and back.board.counts.mine == 2)
	-- Literal and case-insensitive text operators, including characters that are Lua patterns.
	for _, case in {
		{ "contains", "UNIT", true }, { "not_contains", "unit", false },
		{ "starts", "[AGENT]", true }, { "not_starts", "[Agent]", false },
		{ "not_starts", "Skip", true }, { "contains", ".*", false },
	} do
		assert(Model.titleMatches(automatic.title, { { operator = case[1] :: any, value = case[2], enabled = true } }) == case[3])
	end
	-- Row folds follow saved visibility rules too.
	State.setMerged(s, { { repo = "acme/api", number = 9, title = "[Agent] Merged", author = "me", at = Cases.asOfIso } })
	assert(#s.board.recent == 0)
	State.show(s, automatic.key)
	assert(not s.titleRules[1].enabled and State.selectedCard(s), "explicitly showing a hidden PR pauses its matching rule")
	-- Exact, repository-scoped check rules affect placement but never raw check status or mergeability.
	State.beginFilterEdit(s, "check", nil, "acme/api")
	local checkEdit = s.filterEdit :: State.FilterEdit
	checkEdit.field = Fields.create("PR approval")
	assert(State.saveFilter(s))
	assert(State.card(s, approval.key).column == "in_review" and s.board.counts.mine == 2)
	assert(approval.checks.state == "failing" and approval.checks.failing == 1)
	approval.reviews.decision = "approved"
	assert(Model.classify(approval, Cases.asOf, s.ignoredChecks) == "in_review" and not Model.mergeable(approval))
	assert(Model.classify(personal, Cases.asOf, s.ignoredChecks) == "needs_fixes")
	local mixed = pr(4, "Mixed", { "PR approval", "Unit tests" })
	assert(Model.actionableFailures(mixed, s.ignoredChecks) == 1)
	mixed.repo = "another/api"
	assert(Model.actionableFailures(mixed, s.ignoredChecks) == 2)
	mixed.repo = "ACME/API"
	assert(Model.actionableFailures(mixed, s.ignoredChecks) == 1)
	mixed.checks.failedNames = { "PR approval" }
	assert(Model.actionableFailures(mixed, s.ignoredChecks) == 1, "unlisted failures still count")
	mixed.checks.failedNames = nil
	assert(Model.actionableFailures(mixed, s.ignoredChecks) == 2, "old caches and failed reads cannot waive failures")
	approval.conflicts = true
	assert(Model.classify(approval, Cases.asOf, s.ignoredChecks) == "needs_fixes", "other reasons still count")
	approval.conflicts = false
	State.openMenu(s, "filters")
	State.toggleFilter(s, 3)
	assert(s.board.counts.mine == 3 and not s.ignoredChecks[1].enabled)
	back = State.new(copy(s.prs), Cases.asOf, State.saved(s))
	assert(back.ignoredChecks[1].name == "PR approval" and not back.ignoredChecks[1].enabled)
	local bad = State.new({}, Cases.asOf, { titleRules = { { operator = "bad", value = "x", enabled = true }, 1 }, ignoredChecks = { { repo = "no slash", name = "approval", enabled = true } } })
	assert(#bad.titleRules == 0 and #bad.ignoredChecks == 0)
	-- Parser supports both checks and commit status contexts without changing aggregate counts.
	local rollup: any = {
		state = "FAILURE", contexts = {
			checkRunCountsByState = { { state = "FAILURE", count = 1 }, { state = "SUCCESS", count = 2 } },
			statusContextCountsByState = { { state = "ERROR", count = 1 } },
			nodes = { { __typename = "CheckRun", name = "PR approval", conclusion = "FAILURE" }, { __typename = "CheckRun", name = "Passing", conclusion = "SUCCESS" }, { __typename = "StatusContext", context = "External gate", state = "ERROR" } },
		},
	}
	local raw: any = { data = { nodes = { { id = approval.id, headRefOid = approval.headOid, commits = { nodes = { { commit = { statusCheckRollup = rollup } } } } } } } }
	local parsed = Github.parseChecks(raw)
	assert(parsed and parsed.byId[approval.id].checks.failing == 2)
	assert(table.concat(parsed.byId[approval.id].checks.failedNames :: { string }, ",") == "PR approval,External gate")
	local asked = false
	local client = Github.client(function(argv, _opts, done)
		asked = true
		assert(string.find(argv[5], "query CheckNames(", 1, true))
		done({ status = 0, stdout = "names", stderr = "", timed_out = false })
	end, function() return raw end)
	client.checkNames({ approval.id }, function(value, err) assert(value and not err) end)
	assert(asked)
	local batches = 0
	local batched = Github.client(function(argv, _opts, done)
		local count = 0
		for _, arg in argv do if string.sub(arg, 1, 6) == "ids[]=" then count += 1 end end
		assert(count <= 10)
		batches += 1
		done({ status = 0, stdout = "names", stderr = "", timed_out = false })
	end, function() return raw end)
	local many = {}
	for i = 1, 21 do table.insert(many, "PR" .. i) end
	batched.checkNames(many, function(value, err) assert(value and not err) end)
	assert(batches == 3)
	-- On-demand names never land on a replaced snapshot, even when the head is unchanged.
	local oldTimer, oldKv, oldJson, oldEnv = Host.timer, Host.kv, Host.json, Host.getenv
	Host.json = { decode = function() return nil end, encode = function() return "" end }
	Host.getenv = function() return nil end
	local fieldEnv: any = getfenv(Ui.field)
	local oldTern = fieldEnv.tern
	fieldEnv.tern = { ui = { node = function(kind, props) return { k = kind, p = props } end } }
	Host.timer = function(_ms, fn) fn(); return { cancel = function() end } end
	local ok, err = pcall(function()
		local pending: any = nil
		local evidence = State.new({ copy(approval) }, Cases.asOf, { ignoredChecks = { { repo = "acme/api", name = "PR approval", enabled = true } } })
		evidence.prs[1].checks.failedNames = nil
		local b: any = { s = evidence, github = { checkNames = function(_ids, done) pending = done end } }
		local cx: any = { render = function() end }
		CheckFilter.read(b, cx, nil)
		assert(pending)
		local previous = evidence.prs[1].checks
		evidence.prs[1].checks = { state = "failing", passing = 2, failing = 2, pending = 0 }
		pending(parsed, nil)
		assert(evidence.prs[1].checks.failedNames == nil and evidence.prs[1].checks ~= previous)
		CheckFilter.read(b, cx, nil)
		pending(parsed, nil)
		assert(evidence.prs[1].checks.failedNames and evidence.prs[1].checks.failing == 2)
		-- Account preferences survive a new pane and are isolated by viewer; samples never write.
		local records: { [string]: any } = {}
		Host.kv = { get = function(key) return records[key] end, set = function(key, value) records[key] = copy(value) end }
		local prefs: any = { s = s, filterViewer = "WorkUser" }
		FilterStore.save(prefs, cx)
		assert(records["hub.filters.workuser"] and not records["hub.filters.otheruser"])
		local reopened: any = { s = State.new(copy(s.prs), Cases.asOf, nil) }
		FilterStore.load(reopened, cx, "WorkUser")
		assert(reopened.s.ignoredChecks[1].name == "PR approval" and not reopened.s.ignoredChecks[1].enabled)
		FilterStore.load(reopened, cx, "OtherUser")
		assert(#reopened.s.ignoredChecks == 0 and #reopened.s.titleRules == 0)
		local sample: any = { fixture = "cases", s = s, filterViewer = "Sample" }
		FilterStore.save(sample, cx)
		assert(not records["hub.filters.sample"])
		-- A linked PR overrides hiding rules durably, so reopening another pane keeps it visible.
		local linked = State.new({ copy(automatic), copy(personal) }, Cases.asOf, {
			titleRules = { { operator = "not_starts", value = "[Agent]", enabled = true } },
			repositories = { "another/repo" },
		})
		local linkBlock: any = { s = linked, filterViewer = "WorkUser" }
		FilterStore.save(linkBlock, cx)
		State.openLink(linked)
		linked.link = Fields.create("https://github.com/acme/api/pull/1")
		Ops.addByLink(linkBlock, { render = function() end, toast = function() end, frame = function() end }, "")
		assert(linked.selected == automatic.key and not linked.titleRules[1].enabled and linked.repositories == nil)
		local linkedReopened: any = { s = State.new(copy(linked.prs), Cases.asOf, nil) }
		FilterStore.load(linkedReopened, cx, "WorkUser")
		assert(not linkedReopened.s.titleRules[1].enabled and linkedReopened.s.repositories == nil and State.card(linkedReopened.s, automatic.key))
		-- Real block callbacks: F opens Filter, typing letters stays in the field, clicks and keys toggle the same rule.
		local frames = {}
		local blockCx: any = { cwd = "/sample", render = function() end, toast = function() end, frame = function(_self, ops) for _, op in ops do table.insert(frames, op) end end }
		local block = Block.init(blockCx, { "fixture=cases" }, nil)
		local function press(name, text)
			Block.key(block, { name = name, text = text, ctrl = false, meta = false, alt = false, shift = false }, blockCx)
		end
		press("f")
		assert(block.s.menu == "filters" and block.s.keyed)
		press("down"); press("enter")
		assert(block.s.filterEdit and frames[#frames][2] == Paths.filterField)
		press("j", "j"); press("k", "k")
		assert(block.s.filterEdit.field.text == "jk" and block.s.menuCursor == 4)
		press("enter")
		assert(block.s.titleRules[1].value == "jk" and block.s.menu == "filters")
		press("down"); press("space")
		assert(not block.s.titleRules[1].enabled)
		Block.event(block, { ev = "action", act = "hub-filter-toggle", value = "2" }, blockCx)
		assert(block.s.titleRules[1].enabled)
		Block.event(block, { ev = "action", act = "hub-menu-pick", value = "4" }, blockCx)
		assert(block.s.menu == "check-repository")
		press("enter"); press("paste", "PR approval / reviewer gate"); press("enter")
		assert(block.s.ignoredChecks[1].name == "PR approval / reviewer gate" and block.s.ignoredChecks[1].repo == "acme/api")
		local saved = Block.save(block)
		local restoredBlock = Block.init(blockCx, { "fixture=cases" }, saved)
		assert(restoredBlock.s.titleRules[1].enabled and restoredBlock.s.ignoredChecks[1].name == "PR approval / reviewer gate")
		press("escape"); press("f"); press("down"); press("enter")
		local layer = Block.view(block).layer
		local function classOfBody(node)
			if node.p and node.p.key == "body" then return node.p.class end
			for _, child in node.c or {} do local class = classOfBody(child); if class then return class end end
			return nil
		end
		assert(not string.find(classOfBody(layer), "gp-soft", 1, true), "filter text editing never animates")
	end)
	Host.timer, Host.kv, Host.json, Host.getenv = oldTimer, oldKv, oldJson, oldEnv
	fieldEnv.tern = oldTern
	if not ok then error(err, 0) end
end
