--!strict
-- The views of one PR the hub hosts and which pages it keeps: pure rules. A PR is one container with up to three
-- views, Fixes (a card in Needs fixes), Guided (a PR with a guide) and Files, plus "review" for the review page
-- before it has loaded and so doesn't know which of the last two it is. `next` is what `t` does, `tabs` what the
-- tab strips show, and `victims` which kept pages to drop once more than `LIMIT` are open.

export type ViewId = "fixes" | "guided" | "files" | "review"
export type Tab = { id: ViewId, label: string }

local LABELS: { [ViewId]: string } = { fixes = "Fixes", guided = "Guided", files = "Files", review = "Review" }

-- How many opened pages the hub keeps alive.
local LIMIT = 3

local M = {}

M.LIMIT = LIMIT

-- The views in tab order: Fixes when the card has them, then the page's own (`pageViews`, nil before it has loaded).
function M.views(fixes: boolean, pageViews: { ViewId }?): { ViewId }
	local out: { ViewId } = {}
	if fixes then table.insert(out, "fixes") end
	for _, view in pageViews or { "review" :: ViewId } do table.insert(out, view) end
	return out
end

-- The view after `current`, wrapping; nil when there is no other. An unknown `current` goes to the first.
function M.next(views: { ViewId }, current: ViewId): ViewId?
	if #views < 2 then return nil end
	local at = table.find(views, current)
	return views[if at then at % #views + 1 else 1]
end

function M.tabs(views: { ViewId }): { Tab }
	local out: { Tab } = {}
	for _, view in views do table.insert(out, { id = view, label = LABELS[view] }) end
	return out
end

-- The pages to drop, oldest first. `entries` run from least to most recently shown. The newest is never dropped,
-- nor is a page that holds work no file has (`dirty`): when every older page does, more than LIMIT stay.
function M.victims(entries: { { key: string, dirty: boolean } }): { string }
	local out: { string } = {}
	local over = #entries - LIMIT
	for i = 1, #entries - 1 do
		if over <= 0 then break end
		if not entries[i].dirty then
			table.insert(out, entries[i].key)
			over -= 1
		end
	end
	return out
end

return M
