--!strict
-- The pull request actions both the board and a PR's page offer: what each PR offers, why an offered one is refused, the
-- question it asks, and the one command it sends. Also the keys: ⇧P on a hosted page, a row's key in the Pull request
-- menu, and ⌘⏎ on the board, which opens nothing.
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
	assert(ids(PrActions.list(pr("acme/api#109", { behind = true }), ctx({ behind = true }))) == "update,close", "GitHub requires the branch updated first")
	assert(ids(PrActions.list(ready, ctx({ behind = true }))) == "merge,update,close", "a branch behind where GitHub doesn't require it")
	assert(ids(PrActions.list(pr("acme/api#106"), ctx({ column = "in_review" }))) == "auto-merge,close")
	assert(ids(PrActions.list(pr("acme/api#106"), ctx({ column = "in_review", autoMerge = false }))) == "close", "a repo without auto-merge")
	local pending = pr("acme/api#109", { pending = { method = "queue", at = "" } })
	assert(ids(PrActions.list(pending, ctx())) == "cancel-merge", "a pending merge: only Cancel merge, and no Close")
	local review = pr("acme/api#307")
	assert(review.role == "review" and ids(PrActions.list(review, ctx({ column = "to_review" }))) == "", "a review request offers nothing")
	assert(not PrActions.offers(ready, ctx({ agent = true }), "close"), "no Close while an agent works on the branch")
	assert(not PrActions.offers(ready, ctx({ tandem = true }), "close"), "nor on Tandem's branch")
	local comment: Model.MergeResolution = { method = { kind = "comment", command = "/merge" }, source = "declared", ask = false }
	assert(not PrActions.offers(pending, ctx({ merge = comment }), "cancel-merge"), "a comment with no cancel command can't take it back")

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

	-- ⇧P on a hosted page opens the menu when the PR has actions and the page takes letters.
	local host = { rest = true, reading = true, fixes = false, pr = true, status = false }
	local open = Keys.hubPageAction(key("p", true), host)
	assert(open and open.act == "hub-pr-menu")
	assert(Keys.hubPageAction(key("p", true), { rest = true, reading = true, fixes = false, pr = false, status = false }) == nil, "no actions, no menu")
	assert(Keys.hubPageAction(key("p", true), { rest = false, reading = false, fixes = false, pr = true, status = false }) == nil, "a field has the letters")
	assert(Keys.hubPageAction(key("p"), host) == nil, "plain p is the page's")
end
