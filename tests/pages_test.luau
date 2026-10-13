--!strict
-- The hub's PR views: which views a PR has, what `t` does, which hosted pages are dropped, and the keys the hub takes on a page.
local Keys = require("../src/keys")
local PageViews = require("../src/hub/page-views")

return function()
	-- views: Fixes first when the card has them; the page's own after, or "review" until it has loaded
	assert(table.concat(PageViews.views(true, { "guided", "files" }), ",") == "fixes,guided,files")
	assert(table.concat(PageViews.views(true, { "files" }), ",") == "fixes,files")
	assert(table.concat(PageViews.views(true, nil), ",") == "fixes,review")
	assert(table.concat(PageViews.views(false, { "guided", "files" }), ",") == "guided,files")
	assert(table.concat(PageViews.views(false, nil), ",") == "review")

	-- next: `t` cycles and wraps; one view has nowhere to go; an unknown current goes to the first
	local all = PageViews.views(true, { "guided", "files" })
	assert(PageViews.next(all, "fixes") == "guided" and PageViews.next(all, "guided") == "files" and PageViews.next(all, "files") == "fixes")
	local noGuide = PageViews.views(true, { "files" })
	assert(PageViews.next(noGuide, "fixes") == "files" and PageViews.next(noGuide, "files") == "fixes")
	assert(PageViews.next(PageViews.views(false, { "files" }), "files") == nil)
	assert(PageViews.next(PageViews.views(true, nil), "review") == "fixes")
	assert(PageViews.next(all, "review") == "fixes")

	-- tabs carry their labels
	local tabs = PageViews.tabs(all)
	assert(#tabs == 3 and tabs[1].label == "Fixes" and tabs[2].label == "Guided" and tabs[3].label == "Files")
	assert(PageViews.tabs({ "fixes", "review" })[2].label == "Review")

	-- victims: nothing up to the limit; then the oldest, never the newest, and never a page holding unsent work
	local function entries(spec: { string }): { { key: string, dirty: boolean } }
		local out = {}
		for _, item in spec do table.insert(out, { key = string.sub(item, 1, 1), dirty = string.sub(item, 2, 2) == "!" }) end
		return out
	end
	assert(#PageViews.victims(entries({ "a", "b", "c" })) == 0)
	local four = PageViews.victims(entries({ "a", "b", "c", "d" }))
	assert(#four == 1 and four[1] == "a")
	local skipsDirty = PageViews.victims(entries({ "a!", "b", "c", "d" }))
	assert(#skipsDirty == 1 and skipsDirty[1] == "b")
	local allDirty = PageViews.victims(entries({ "a!", "b!", "c!", "d" }))
	assert(#allDirty == 0)
	local two = PageViews.victims(entries({ "a", "b", "c", "d", "e" }))
	assert(#two == 2 and two[1] == "a" and two[2] == "b")
	assert(#PageViews.victims(entries({ "a!", "b", "c", "d!", "e" })) == 2)

	-- the hub's keys on a page: Esc at rest goes back, `t` cycles only with Fixes and a reading page, the rest is the page's
	local function press(name: string, mods: any?): Key
		local key: any = { name = name }
		for mod, on in mods or {} do key[mod] = on end
		return key
	end
	local rest = { rest = true, reading = true, fixes = true, status = false }
	local act = Keys.hubPageAction(press("escape"), rest)
	assert(act and act.act == "pages-back")
	assert(Keys.hubPageAction(press("escape"), { rest = false, reading = false, fixes = true, status = false }) == nil)
	act = Keys.hubPageAction(press("t"), rest)
	assert(act and act.act == "pages-cycle")
	assert(Keys.hubPageAction(press("t"), { rest = true, reading = true, fixes = false, status = false }) == nil)
	assert(Keys.hubPageAction(press("t"), { rest = false, reading = false, fixes = true, status = false }) == nil)
	assert(Keys.hubPageAction(press("t", { meta = true }), rest) == nil)
	assert(Keys.hubPageAction(press("j"), rest) == nil)

	-- `v` on a page with the PR's status marks opens the reviewers and checks; without them, or while a field has the
	-- letters, it is the page's
	local status = { rest = true, reading = true, fixes = false, status = true }
	act = Keys.hubPageAction(press("v"), status)
	assert(act and act.act == "hub-checks" and act.value == nil)
	assert(Keys.hubPageAction(press("v"), rest) == nil)
	assert(Keys.hubPageAction(press("v"), { rest = false, reading = false, fixes = false, status = true }) == nil)
	assert(Keys.hubPageAction(press("v", { shift = true }), status) == nil)
end
