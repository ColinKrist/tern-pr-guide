--!strict
-- The pull request actions both the board and a PR's page offer: what each PR offers, why an offered one is refused, the
-- question it asks, and the one command it sends. Also the rows the hub adds to a review page's Actions menu, the keys
-- of the fixes page's Pull request menu, and ⌘⏎ on the board, which opens nothing.
local FakeRunner = require("./fake-runner")
local Github = require("../src/github")
local HubState = require("../src/hub/state")
local Keys = require("../src/keys")
local Model = require("../src/hub/model")
local PrActions = require("../src/pr-actions")
local Cases: any = require("../fixtures/hub/cases")

local function pr(key: string, patch: { [string]: any }?): Model.HubPR
	for _, case in Cases.prs do
		if case.key == key then
			local out = table.clone(case)
			for field, value in patch or {} do out[field] = value end
			return out
		end
	end
	error("no case " .. key, 0)
end

local SQUASH: Model.MergeResolution = { method = { kind = "squash" }, source = "user", ask = false }

local function ctx(patch: { [string]: any }?): PrActions.Ctx
	local out: any = { column = "ready", merge = SQUASH, autoMerge = true, tandem = false, readable = true, agent = false, behind = false }
	for field, value in patch or {} do out[field] = value end
	return out
end

local function ids(list: { PrActions.Action }): string
	local out: { string } = {}
	for _, action in list do table.insert(out, action.id) end
	return table.concat(out, ",")
end

-- Runs `id` against a fake `gh` that answers `reply`, and returns the one argv it sent and the error it heard.
local function sent(id: PrActions.Id, target: Model.HubPR, c: PrActions.Ctx, reply: FakeRunner.Reply?): (string, string?)
	local fake = FakeRunner.new({ { prefix = { "gh" }, reply = reply or {} } })
	local heard: string? = "never answered"
	PrActions.get(id).run(target, c, Github.client(fake.run, function() return nil end), function(err) heard = err end)
	fake.expectOnly(1)
	return table.concat(fake.calls[1].argv, " "), heard
end

local function key(name: string, shift: boolean?, meta: boolean?): Key
	return { name = name, shift = shift or false, meta = meta or false, ctrl = false, alt = false } :: any
end

return function()
	local ready = pr("acme/api#109")
	local merge = PrActions.get("merge")

	-- What a PR offers follows where the board places it and what is in flight on it.
	assert(ids(PrActions.list(ready, ctx())) == "merge,close", ids(PrActions.list(ready, ctx())))
	assert(ids(PrActions.list(pr("acme/api#109", { behind = true }), ctx({ behind = true }))) == "force-merge,update,close", "GitHub requires the branch updated first")
	assert(ids(PrActions.list(ready, ctx({ behind = true }))) == "merge,update,close", "a branch behind where GitHub doesn't require it")
	assert(ids(PrActions.list(pr("acme/api#106"), ctx({ column = "in_review" }))) == "force-merge,auto-merge,close")
	assert(ids(PrActions.list(pr("acme/api#106"), ctx({ column = "in_review", autoMerge = false }))) == "force-merge,close", "a repo without auto-merge")
	local pending = pr("acme/api#109", { pending = { method = "queue", at = "" } })
	assert(ids(PrActions.list(pending, ctx())) == "cancel-merge", "a pending merge: only Cancel merge, and no Close")
	local review = pr("acme/api#307")
	assert(review.role == "review" and ids(PrActions.list(review, ctx({ column = "to_review" }))) == "approve,request-changes", "a review request offers approve and request-changes")

	-- Approve and request-changes: offered gates and withheld cases.
	assert(PrActions.offers(review, ctx({ column = "to_review" }), "approve"), "offers approve in to_review")
	assert(PrActions.offers(review, ctx({ column = "to_review" }), "request-changes"), "offers request-changes in to_review")
	assert(PrActions.offers(review, ctx({ column = "team" }), "approve"), "offers approve in team")
	assert(PrActions.offers(review, ctx({ column = "team" }), "request-changes"), "offers request-changes in team")

	-- Withheld: not a review-role PR
	assert(not PrActions.offers(ready, ctx({ column = "to_review" }), "approve"), "mine role does not offer approve")
	assert(not PrActions.offers(ready, ctx({ column = "to_review" }), "request-changes"), "mine role does not offer request-changes")
	assert(not PrActions.offers(ready, ctx({ column = "team" }), "approve"))
	assert(not PrActions.offers(ready, ctx({ column = "team" }), "request-changes"))

	-- Withheld: a draft PR
	local draftReview = pr("acme/api#307", { draft = true })
	assert(not PrActions.offers(draftReview, ctx({ column = "to_review" }), "approve"), "draft does not offer approve")
	assert(not PrActions.offers(draftReview, ctx({ column = "to_review" }), "request-changes"), "draft does not offer request-changes")

	-- Withheld: non to_review/team columns
	for _, col in { "ready", "in_review", "needs_fixes", "approved", "waiting_on_author", "inactive" } :: { Model.Column } do
		assert(not PrActions.offers(review, ctx({ column = col }), "approve"), col .. " does not offer approve")
		assert(not PrActions.offers(review, ctx({ column = col }), "request-changes"), col .. " does not offer request-changes")
	end

	-- Withheld: already that verdict
	local alreadyApproved = pr("acme/api#307")
	local appReviews = table.clone(alreadyApproved.reviews)
	appReviews.mine = { author = "me", bot = false, verdict = "approved", at = "", oid = "head" }
	alreadyApproved.reviews = appReviews
	assert(not PrActions.offers(alreadyApproved, ctx({ column = "to_review" }), "approve"), "already approved does not offer approve")
	assert(PrActions.offers(alreadyApproved, ctx({ column = "to_review" }), "request-changes"), "already approved still offers request-changes")

	local alreadyChanges = pr("acme/api#307")
	local chReviews = table.clone(alreadyChanges.reviews)
	chReviews.mine = { author = "me", bot = false, verdict = "changes_requested", at = "", oid = "head" }
	alreadyChanges.reviews = chReviews
	assert(PrActions.offers(alreadyChanges, ctx({ column = "to_review" }), "approve"), "already changes-requested still offers approve")
	assert(not PrActions.offers(alreadyChanges, ctx({ column = "to_review" }), "request-changes"), "already changes-requested does not offer request-changes")

	-- Refusal, question, progress, and run
	local approveDef = PrActions.get("approve")
	local requestChangesDef = PrActions.get("request-changes")
	assert(approveDef.refusal(review, ctx({ column = "to_review" })) == nil)
	assert(requestChangesDef.refusal(review, ctx({ column = "to_review" })) == nil)
	assert(approveDef.question(review, ctx({ column = "to_review" })) == "Approve #307?")
	assert(requestChangesDef.question(review, ctx({ column = "to_review" })) == "Request changes on #307?")
	assert(approveDef.progress(review, ctx({ column = "to_review" })) == "Approving…")
	assert(requestChangesDef.progress(review, ctx({ column = "to_review" })) == "Requesting changes…")
	assert(sent("approve", review, ctx({ column = "to_review" })) == "gh pr review 307 --repo acme/api --approve")
	assert(sent("request-changes", review, ctx({ column = "to_review" })) == "gh pr review 307 --repo acme/api --request-changes")
	assert(not PrActions.offers(ready, ctx({ agent = true }), "close"), "no Close while an agent works on the branch")
	assert(not PrActions.offers(ready, ctx({ tandem = true }), "close"), "nor on Tandem's branch")
	local comment: Model.MergeResolution = { method = { kind = "comment", command = "/merge" }, source = "declared", ask = false }
	assert(not PrActions.offers(pending, ctx({ merge = comment }), "cancel-merge"), "a comment with no cancel command can't take it back")

	-- Force-merge: merge on GitHub a PR the board doesn't place in Ready, with the repo's known direct method.
	local notReady = pr("acme/api#106")
	assert(PrActions.offers(notReady, ctx({ column = "in_review" }), "force-merge"), "a not-ready PR offers force-merge")
	assert(not PrActions.offers(notReady, ctx({ column = "in_review", tandem = true }), "force-merge"), "nor on Tandem's branch")
	assert(not PrActions.offers(pr("acme/api#105"), ctx({ column = "needs_fixes" }), "force-merge"), "a conflicting PR doesn't offer it")
	assert(not PrActions.offers(ready, ctx(), "force-merge"), "a ready PR merges for real, not forced")
	assert(not PrActions.offers(notReady, ctx({ column = "in_review", merge = { method = { kind = "queue" }, source = "user", ask = false } }), "force-merge"), "a queue method is not a GitHub merge")
	local unknownMerge = ctx({ column = "in_review" })
	unknownMerge.merge = nil
	assert(not PrActions.offers(notReady, unknownMerge, "force-merge"), "an unknown method is not a guess")
	assert(not PrActions.offers(pr("acme/web#113"), ctx({ column = "needs_fixes" }), "force-merge"), "a draft doesn't offer it")
	assert(PrActions.get("force-merge").refusal(notReady, ctx({ column = "in_review" })) == nil)
	assert(PrActions.get("force-merge").refusal(notReady, ctx({ column = "in_review", tandem = true })) == "Tandem watches this pull request")
	assert(PrActions.get("force-merge").refusal(notReady, ctx({ column = "in_review", readable = false })) == "Tandem's ownership couldn't be checked")
	assert(PrActions.get("force-merge").question(notReady, ctx({ column = "in_review" })) == "Force-merge #106? It is not ready.")
	assert(PrActions.get("force-merge").progress(notReady, ctx({ column = "in_review" })) == "Force-merging…")

	-- Merge never guesses and never reaches a branch whose owner isn't the viewer.
	assert(merge.refusal(ready, ctx()) == nil)
	assert(merge.refusal(ready, ctx({ tandem = true })) == "Tandem watches this pull request")
	assert(merge.refusal(ready, ctx({ readable = false })) == "Tandem's ownership couldn't be checked")
	local unknown = ctx()
	unknown.merge = nil
	assert(merge.refusal(ready, unknown) == "how acme/api merges isn't known yet")
	assert(PrActions.get("update").refusal(ready, ctx({ tandem = true })) == "Tandem watches this pull request")
	assert(PrActions.get("close").refusal(ready, ctx({ tandem = true })) == nil, "closing touches no branch")
	assert(PrActions.get("cancel-merge").refusal(pr("acme/api#109", { pending = { method = "label", at = "" } }), ctx()) == "acme/api has no way to cancel it")

	-- The question: a GitHub method and Close ask; a method that can be cancelled runs at once; a learned comment asks once.
	assert(merge.question(ready, ctx()) == "Squash and merge #109?")
	assert(merge.question(ready, ctx({ merge = { method = { kind = "rebase" }, source = "user", ask = false } })) == "Rebase and merge #109?")
	assert(merge.question(ready, ctx({ merge = { method = { kind = "queue" }, source = "declared", ask = false } })) == nil)
	assert(merge.question(ready, ctx({ merge = { method = { kind = "comment", command = "/merge" }, source = "learned", ask = true } }))
		== "Comment /merge, as this repository usually does?")
	assert(PrActions.get("close").question(ready, ctx()) == "Close #109?")
	assert(PrActions.get("update").question(ready, ctx()) == nil)

	-- Each sends its one command, and a failure comes back as the reason.
	assert(sent("close", ready, ctx()) == "gh pr close 109 --repo acme/api")
	assert(sent("merge", ready, ctx()) == "gh pr merge 109 --repo acme/api --squash")
	assert(sent("merge", ready, ctx({ merge = comment })) == "gh pr comment 109 --repo acme/api --body /merge")
	assert(sent("force-merge", notReady, ctx({ column = "in_review" })) == "gh pr merge 106 --repo acme/api --squash")
	assert(sent("cancel-merge", pending, ctx()) == "gh pr merge 109 --repo acme/api --disable-auto")
	assert(sent("update", ready, ctx({ behind = true })) == "gh pr update-branch 109 --repo acme/api")
	local argv, err = sent("close", ready, ctx(), { status = 1, stderr = "GraphQL: Could not close" })
	assert(argv == "gh pr close 109 --repo acme/api" and err ~= nil and string.find(err, "Could not close", 1, true) ~= nil, tostring(err))
	local _, ok = sent("close", ready, ctx())
	assert(ok == nil, "a close that went through hears no error")

	-- The board lists the same actions in its cards and its Pull request menu.
	local s = HubState.new(Cases.prs, Cases.asOf, nil)
	s.merges["acme/api"] = SQUASH
	HubState.project(s)
	local menu: { string } = {}
	for _, row in HubState.prMenu(s, "acme/api#109") do table.insert(menu, row.act .. ":" .. row.key) end
	assert(table.concat(menu, ",") == "card-merge:M,card-close:X", table.concat(menu, ","))
	assert(#HubState.prMenu(s, "acme/api#307") == 0, "a review request has no Pull request menu")

	-- ⌘⏎ on the board opens nothing; it still confirms an inline question.
	HubState.select(s, "acme/api#109")
	assert(Keys.hubAction(s, key("enter", false, true)) == nil, "⌘⏎ on the board")
	assert(HubState.ask(s, "acme/api#109", "close"))
	local confirm = Keys.hubAction(s, key("enter", false, true))
	assert(confirm and confirm.act == "hub-confirm")
	HubState.cancelConfirm(s)

	-- In the Pull request menu a row's own key chooses it, and j, ⏎ and Esc work as in every menu.
	HubState.openMenu(s, "pr")
	local pick = Keys.hubAction(s, key("x"))
	assert(pick and pick.act == "hub-menu-pick" and pick.value == "2", "X chooses Close")
	local down = Keys.hubAction(s, key("j"))
	assert(down and down.act == "hub-menu-move")
	local escape = Keys.hubAction(s, key("escape"))
	assert(escape and escape.act == "hub-menu-close")
	HubState.closeMenu(s)

	-- A review page's Actions menu: the hub adds the PR's actions, each in its group, and Copy link; nothing for a PR off
	-- the board.
	local function page(list: { Model.HubPR }, key: string?, tab: string?): string
		local board = HubState.new(list, Cases.asOf, nil)
		board.tab = (tab or "mine") :: any
		board.merges["acme/api"] = SQUASH
		board.autoMerge["acme/api"] = true
		HubState.project(board)
		local out: { string } = {}
		for _, row in HubState.pageActions(board, key) do table.insert(out, row.act .. ":" .. row.key .. ":" .. row.group .. ":" .. tostring(row.value)) end
		return table.concat(out, ",")
	end
	local function with(key: string, patch: { [string]: any }): { Model.HubPR }
		local list: { Model.HubPR } = {}
		for _, case in Cases.prs do table.insert(list, if case.key == key then pr(key, patch) else case) end
		return list
	end
	local mine = page(Cases.prs, "acme/api#109")
	assert(mine == "card-merge:M:land:acme/api#109,card-close:X:close:acme/api#109,card-copy:C:links:acme/api#109", mine)
	local behind = page(with("acme/api#106", { behind = true }), "acme/api#106")
	assert(behind == "card-force:M:land:acme/api#106,card-auto:M:land:acme/api#106,card-update:U:land:acme/api#106,card-close:X:close:acme/api#106,card-copy:C:links:acme/api#106", behind)
	local queued = page(with("acme/api#109", { pending = { method = "queue", at = "" } }), "acme/api#109")
	assert(queued == "card-cancel:M:land:acme/api#109,card-copy:C:links:acme/api#109", "a queued merge: Cancel merge and Copy link, no Close: " .. queued)
	local request = page(Cases.prs, "acme/api#307", "review")
	assert(request == "card-approve::review:acme/api#307,card-request::review:acme/api#307,card-copy:C:links:acme/api#307", "a review request: Approve, Request changes and Copy link: " .. request)

	-- Optimistic review update
	local revBoard = HubState.new(Cases.prs, Cases.asOf, nil)
	revBoard.tab = "review"
	HubState.project(revBoard)
	local c307 = HubState.card(revBoard, "acme/api#307")
	assert(c307 and c307.column == "to_review")
	-- Review page action rows (group "review")
	local ReviewPageState = require("../src/state")
	local reviewPage = ReviewPageState.new(
		{ repo = "acme/api", number = 307, files = {}, branch = "main", head = "head", base = "base", title = "T", url = "" } :: any,
		{ title = "Test", summary = "", guided = false, steps = {}, changes = {}, comments = {} } :: any,
		{ repo = "acme/api", dryRunPath = nil, root = "main" }
	)
	reviewPage.hosted = { actions = HubState.pageActions(revBoard, "acme/api#307"), asking = false }
	local rows = ReviewPageState.actionRows(reviewPage)
	local acts = {}
	for _, r in rows do table.insert(acts, r.act .. ":" .. r.group .. ":" .. tostring(r.host)) end
	assert(table.concat(acts, ",") == "card-approve:review:true,card-request:review:true,mark-all:review:false,card-copy:links:true,open-github:links:false", table.concat(acts, ","))

	-- Optimistic review update
	HubState.reviewed(revBoard, "acme/api#307", "approved")
	c307 = HubState.card(revBoard, "acme/api#307")
	assert(c307 and c307.column == "approved", "reviewed approved reclassifies to approved")
	HubState.reviewed(revBoard, "acme/api#307", "changes_requested")
	c307 = HubState.card(revBoard, "acme/api#307")
	assert(c307 and c307.column == "waiting_on_author", "reviewed changes_requested reclassifies to waiting_on_author")
	assert(page(Cases.prs, nil) == "" and page(Cases.prs, "acme/none#1") == "", "a PR off the board: none")
end
