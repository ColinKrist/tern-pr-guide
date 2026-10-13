--!strict
-- Loads and remembers the viewer's personal filter rules, independently of a hub pane's navigation.
local Fetch = require("../fetch")
local Runtime = require("./runtime")
local State = require("./state")

local M = {}

function M.save(b: Runtime.Block, cx: BlockCx)
	if b.fixture or b.closed then return end
	b.filtersDirty = true
	local viewer = b.filterViewer
	if not viewer then return end
	local why = Fetch.saveHubFilters(viewer, State.savedFilters(b.s))
	if why then cx:toast("error", "Couldn't save filters: " .. why)
	else b.filtersDirty = false end
end

function M.load(b: Runtime.Block, cx: BlockCx, viewer: string)
	if b.fixture or b.closed or b.filterViewer == viewer then return end
	local previous = b.filterViewer
	b.filterViewer = viewer
	if b.filtersDirty and not previous then return M.save(b, cx) end
	local saved, why = Fetch.hubFilters(viewer)
	if why then
		b.s.error = { operation = "hub.filters", message = "Couldn't load filters: " .. why }
		return
	end
	if saved then State.loadFilters(b.s, saved)
	elseif previous then State.loadFilters(b.s, { schema = 1 }) end
	-- Persist pane-restored rules when this account has no preference record yet.
	if not saved and not previous then M.save(b, cx) end
end

return M
