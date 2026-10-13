--!strict
-- The `?` panel: shortcuts for the page the reader is on.
local Paths = require("./paths")
local State = require("../../hub/state")
local Ui = require("../ui")

local el, span = Ui.el, Ui.span

type Group = { title: string, keys: { { string } } } -- a key row is { keys, label, keys on a second line? }
type Page = "board" | "fixes" | "review-fix"

local GROUPS: { [Page]: { Group } } = {
	board = {},
	fixes = {
		{ title = "Fixes", keys = {
			{ "j k", "Next or previous step, or action" },
			{ "h l", "Between the steps and the code", "← →" },
			{ "⏎", "Go to the code, or choose" },
			{ "R", "Reply to the thread (⌘⏎ posts)" },
			{ "E", "Resolve the thread" },
			{ "⇧L", "View the check's log" },
			{ "⇧R", "Re-run failed checks" },
			{ "G", "Open on GitHub, or resolve a conflict there" },
			{ "B", "Show or hide bot comments" },
			{ "Esc", "Back to the board" },
			{ "?", "Close shortcuts" },
		} },
	},
	["review-fix"] = {
		{ title = "Review fix", keys = {
			{ "j k", "Next or previous conflict", "↑ ↓" },
			{ "⏎", "Mark the conflict reviewed or unreviewed" },
			{ "B", "Switch between the resolution and original conflict" },
			{ "P", "Push after every conflict is reviewed, or retry lease return" },
			{ "D", "Discard fix (⌘⏎ or Ctrl+Enter confirms)" },
			{ "Esc", "Cancel Discard, or return to the board" },
			{ "?", "Close shortcuts" },
		} },
	},
}

local TITLES: { [Page]: string } = { board = "PR hub", fixes = "Fixes", ["review-fix"] = "Review fix" }
local ANCHORS: { [Page]: string } = {
	board = Paths.titleLabel,
	fixes = Paths.fixesTitle,
	["review-fix"] = Paths.reviewFixTitle,
}

local M = {}

local function boardGroups(s: State.State): { Group }
	local move: { { string } } = {
		{ "h j k l", "Move between cards", "← ↑ ↓ →" },
		{ "⏎", "Open the card, fixes page, or a Fix ready card for review" },
		{ "⇧⏎", "Open with the AI guide started" },
		{ ".", "Next pull request that needs you" },
		{ "T", "Switch tab" },
		{ "I", "Show or hide Inactive" },
		{ "R", "Show or hide Recently merged, or Recently opened on Review requests" },
	}
	if s.tab == "review" then
		table.insert(move, 7, { "⇧T", "Show or hide Team requests" })
		table.insert(move, 8, { "A", "Show or hide Approved" })
	end
	local groups: { Group } = { { title = "Move", keys = move } }
	local card = State.selectedCard(s)
	if card then
		local keys: { { string } } = {}
		if card.main and card.main.key and card.main.key ~= "⏎" then table.insert(keys, { card.main.key, card.main.label }) end
		for _, more in card.more do
			if more.key and more.key ~= "⏎" then table.insert(keys, { more.key, more.label }) end
		end
		if #keys > 0 then table.insert(groups, { title = "The selected card", keys = keys }) end
	end
	local board: { { string } } = {
		{ "/", "Search" },
		{ "N", "Add a pull request by link" },
		{ "F", "Filter by repository" },
		{ "S", "Sort" },
		{ "⇧S", "Settings: models, effort, lens and where links open (also ⇧M)" },
		{ "⌘R", "Refresh" },
		{ "Space", "Select a card to merge or close" },
	}
	if s.tab == "mine" then table.insert(board, { "⇧X", "Select stale pull requests to close" }) end
	if next(s.marked) ~= nil then table.insert(board, { "M X", "Merge or close the selected cards (⌘⏎ confirms)" }) end
	table.insert(board, { "Esc", "Clear, cancel or close" })
	table.insert(board, { "?", "Close shortcuts" })
	table.insert(groups, { title = "The board", keys = board })
	return groups
end

function M.view(page: Page, s: State.State): Node
	local cols: { Node } = {}
	local groups = if page == "board" then boardGroups(s) else GROUPS[page]
	for _, group in groups do
		local rows: { Node } = { span("gp-panel-h", group.title) }
		for _, key in group.keys do
			local caps: { Node } = { Ui.keys(key[1]) }
			if key[3] then table.insert(caps, Ui.keys(key[3])) end
			local row: { Node } = { el("span", { class = "gp-hh-keys" }, caps), span("gp-keylabel", key[2]) }
			table.insert(rows, el("div", { class = "gp-keyrow" }, row))
		end
		table.insert(cols, el("div", { class = "gp-keycol" }, rows))
	end
	local body = el("div", { class = "gp-hh", key = "body" }, cols)
	return { k = "overlay", p = { key = "help", role = "gp.hubhelp", aria = TITLES[page] .. " shortcuts", anchor = { node = ANCHORS[page], side = "below" }, size = "lg" }, c = { body } } :: any
end

return M
