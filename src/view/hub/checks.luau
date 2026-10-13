--!strict
-- The checks popover (a Tern overlay under a card's checks mark, the fixes page's All checks row or a PR page's status
-- marks), the checks mark itself, and the popover's keys for the hint bar. Everything it draws was decided by
-- `State.checkLines` and `Checks`.
local Checks = require("../../hub/checks")
local Paths = require("./paths")
local State = require("../../hub/state")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

local M = {}

local function stateIcon(state: Checks.CheckState): Node
	if state == "failing" then return el("span", { class = "gp-hcl-ic gp-hcl-ic-fail" }, { Ui.icon("x") }) end
	if state == "running" then return el("span", { class = "gp-hcl-ic" }, { span("gp-hc-spin", "") }) end
	if state == "queued" then return el("span", { class = "gp-hcl-ic" }, { span("gp-hcl-queue", "") }) end
	if state == "skipped" then return el("span", { class = "gp-hcl-ic gp-hcl-ic-skip" }, { Ui.icon("minus") }) end
	return el("span", { class = "gp-hcl-ic gp-hcl-ic-pass" }, { Ui.icon("check") })
end

-- The checks mark on a card's meta line, or the All checks row's summary: failing in red, unfinished in amber with the
-- spinner, then (when `passed` is asked for, or nothing else shows) the green count.
function M.summary(mark: Checks.Mark, withPassed: boolean): { Node }
	local out: { Node } = {}
	local function sep()
		if #out > 0 then table.insert(out, span("gp-hcl-sep", "·")) end
	end
	if mark.failing > 0 then
		table.insert(out, el("span", { class = "gp-hc-ci gp-hc-ci-bad", key = "bad" }, { Ui.icon("x"), span("gp-hc-ci-n", tostring(mark.failing)) }))
	end
	if mark.pending > 0 then
		sep()
		table.insert(out, el("span", { class = "gp-hc-ci gp-hc-ci-run", key = "run" }, { span("gp-hc-spin", ""), span("gp-hc-ci-n", mark.pending .. " pending") }))
	end
	if withPassed or #out == 0 then
		sep()
		table.insert(out, el("span", { class = "gp-hc-ci gp-hc-ci-ok", key = "ok" }, { Ui.icon("check"), span("gp-hc-ci-n", mark.passed .. (if withPassed then " passed" else "")) }))
	end
	return out
end

-- A card's checks mark: a button that opens the popover. `open`: the popover is showing for this card.
function M.mark(key: string, mark: Checks.Mark, open: boolean): Node
	return el("span", { class = "gp-hc-chk" .. (if open then " gp-hc-chk-open" else ""), key = "ci", actions = { click = "hub-checks=" .. key } }, M.summary(mark, false))
end

local function lineNode(line: Checks.Line, index: number, hl: number): Node
	if line.kind == "header" then
		local kids: { Node } = { span("gp-hcl-hl", line.label), span("gp-hcl-n", tostring(line.count)) }
		if line.skipped > 0 then table.insert(kids, span("gp-hcl-hl", "· Skipped " .. line.skipped)) end
		return el("div", { class = "gp-hcl-h", key = "h" .. line.label }, kids)
	end
	local on = if index == hl then " gp-hcl-row-on" else ""
	if line.kind == "more" then
		return el("div", { class = "gp-hcl-row gp-hcl-more" .. on, key = "more", actions = { click = "checks-pick=" .. index } }, {
			el("span", { class = "gp-hcl-ic" }, { Ui.icon("chev-r") }),
			span("gp-hcl-name", "Show " .. line.count .. (if line.fresh then " more" else "")),
		})
	end
	local row = line.row
	return el("div", { class = "gp-hcl-row" .. (if row.state == "skipped" then " gp-hcl-skip" else "") .. on, key = "c" .. index, actions = { click = "checks-pick=" .. index } }, {
		stateIcon(row.state),
		el("span", { class = "gp-hcl-text" }, { span("gp-hcl-name", row.name), span("gp-hcl-sub", line.sub) }),
	})
end

local function reviewerIcon(state: Checks.ReviewerState): Node
	if state == "approved" then return el("span", { class = "gp-hcl-ic gp-hcl-ic-pass" }, { Ui.icon("check") }) end
	if state == "changes" then return el("span", { class = "gp-hcl-ic gp-hcl-ic-fail" }, { Ui.icon("x") }) end
	if state == "commented" then return el("span", { class = "gp-hcl-ic" }, { Ui.icon("message") }) end
	return el("span", { class = "gp-hcl-ic" }, { span("gp-hcl-wait", "") })
end

-- Who reviewed and who is asked, above the checks. Not rows the highlight rests on: j and k move through the checks.
local function reviewersNode(reviewers: { Checks.Reviewer }): Node
	local kids: { Node } = { el("div", { class = "gp-hcl-h", key = "h" }, { span("gp-hcl-hl", "Reviewers"), span("gp-hcl-n", tostring(#reviewers)) }) }
	if #reviewers == 0 then table.insert(kids, span("gp-hcl-empty", "No reviewers")) end
	for index, reviewer in reviewers do
		table.insert(kids, el("div", { class = "gp-hcl-rv-row", key = "r" .. index }, {
			span("gp-hcl-rv-name", reviewer.name), span("gp-hcl-rv-sub", reviewer.sub), reviewerIcon(reviewer.state),
		}))
	end
	return el("div", { class = "gp-hcl-rv", key = "reviewers" }, kids)
end

-- Where the popover hangs: the All checks row on the fixes page, a PR page's status marks (`page`), else the card's
-- checks mark, or the card itself while its mark is hidden (no checks, or a question in place of its meta line's lead).
local function anchorOf(s: State.State, pop: Checks.Popover, page: string?): string
	if pop.from == "fixes" then return Paths.allChecks end
	if pop.from == "page" and page then return page end
	local card = State.card(s, pop.key)
	if card == nil then return Paths.titleLabel end
	if Checks.mark(card.pr.checks) == nil or card.asking then return Paths.card(card) end
	return Paths.checksMark(card)
end

function M.view(s: State.State, page: string?): Node?
	local pop = s.checks
	local pr = if pop then State.prOf(s, pop.key) else nil
	if pop == nil or pr == nil then return nil end
	local lines, load = State.checkLines(s)
	local sha = string.sub(if load and load.state == "loaded" then load.list.headOid else pr.headOid, 1, 7)
	local body: { Node } = {}
	if load == nil or load.state == "loading" then
		for i = 1, 3 do
			table.insert(body, el("div", { class = "gp-hcl-skel", key = "sk" .. i }, { span("gp-hcl-skel-dot", ""), span("gp-hcl-skel-bar gp-hcl-skel-" .. i, "") }))
		end
	elseif load.state == "failed" then
		table.insert(body, el("div", { class = "gp-hcl-err", key = "err", actions = { click = "checks-press" } }, {
			span("gp-hcl-err-t", "Couldn't load checks: " .. load.reason), Ui.spacer(), Ui.keys("⏎"),
		}))
	elseif #lines == 0 then
		table.insert(body, span("gp-hcl-empty", "No checks on " .. sha))
	else
		local index = 0
		for _, line in lines do
			if line.kind ~= "header" then index += 1 end
			table.insert(body, lineNode(line, if line.kind == "header" then 0 else index, pop.hl))
		end
	end
	-- The fixes page's All checks row is about checks alone; a card or a PR page also shows who reviewed.
	local parts: { Node } = {}
	local withReviewers = pop.from ~= "fixes"
	if withReviewers then table.insert(parts, reviewersNode(Checks.reviewers(pr.reviews, s.now))) end
	table.insert(parts, el("div", { class = "gp-hcl-top", key = "top" }, { span("gp-hcl-t", "Checks"), span("gp-hcl-sha", sha) }))
	table.insert(parts, el("div", { class = "gp-hcl-list", key = "list" }, body))
	local card = el("div", { class = "gp-md gp-hcl" .. (if s.keyed then "" else " gp-soft"), key = "body" }, parts)
	local aria = if withReviewers then "Reviewers and checks" else "Checks"
	return { k = "overlay", p = { key = "checks", role = "gp.hubchecks", aria = aria, anchor = { node = anchorOf(s, pop, page), side = "below" }, size = "md" }, c = { card } } :: any
end

-- The popover's keys for the hint bar, in the order they matter.
function M.hints(s: State.State): { { string } }
	local lines, load = State.checkLines(s)
	local keys: { { string } } = {}
	if load and load.state == "failed" then
		table.insert(keys, { "⏎", "Try again" })
	elseif #lines > 0 then
		local pop = s.checks :: Checks.Popover
		local line = Checks.choices(lines)[pop.hl]
		table.insert(keys, { "j k", "Move" })
		table.insert(keys, { "⏎", if line and line.kind == "more" then "Show passed" else "Open" })
	end
	if State.checksFailing(s) then table.insert(keys, { "⇧R", "Re-run failed" }) end
	table.insert(keys, { "esc", "Close" })
	return keys
end

return M
