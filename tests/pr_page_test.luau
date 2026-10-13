--!strict
-- A PR's page in the hub offers the PR's pull request actions in the page's Actions menu: ⇧P opens it under the page's
-- Actions button with the hub's rows first in each group, a row's letter runs it, Close asks "Close #n?" under the same
-- button, ⌘⏎ answers it (a sample board only says it doesn't close), and Esc closes the menu or the question before it
-- leaves the page. `u` updates the branch only when the PR offers it. `v` and a click on its status marks open its
-- reviewers and checks.
local Block: any = require("../src/hub/block")
local Host: any = require("../src/host")
local Review = require("../src/review")
local Ui: any = require("../src/view/ui")

-- Every overlay in the layer, by its anchor.
local function overlays(node: any, out: { any }?): { any }
	local list = out or {}
	if type(node) ~= "table" then return list end
	if node.k == "overlay" then table.insert(list, node) end
	for _, child in node.c or {} do overlays(child, list) end
	return list
end

local function texts(node: any, out: { string }?): { string }
	local list = out or {}
	if type(node) ~= "table" then return list end
	if node.p and type(node.p.text) == "string" and node.p.text ~= "" then table.insert(list, node.p.text) end
	for _, child in node.c or {} do texts(child, list) end
	return list
end

return function()
	local fieldEnv: any = getfenv(Ui.field)
	local hostField = fieldEnv.tern
	local stub: { [string]: any } = {
		timer = function(_ms: number, fn: () -> ()): any
			fn()
			return { cancel = function() end }
		end,
		-- The page's sample PR: one changed file, and a guide file with no changes in it.
		fs = {
			read = function(path: string): string?
				if string.find(path, "fixtures/guide-", 1, true) then return "GUIDE" end
				return if string.find(path, "fixtures/pr-", 1, true) then "SAMPLE" else nil
			end,
			exists = function(): boolean return false end,
		},
		json = { decode = function(text: string): any
			if text == "GUIDE" then return { schema = 1 } end
			if text ~= "SAMPLE" then return nil end
			local rows = { { kind = "hunk", oldStart = 1, newStart = 1 }, { kind = "add", text = "x", new = 1 } }
			return { pr = { repo = "acme/api", number = 350, title = "Sample", body = "", url = "", author = "", createdAt = "", baseRef = "main", head = "abc" },
				files = { { path = "a.ts", status = "modified", adds = 1, dels = 0, rows = rows } } }
		end, encode = function(): string return "" end },
		getenv = function(): string? return nil end,
		runtime = { os = "linux" },
		kv = { get = function(): any return nil end, set = function() end },
	}
	local hostFields: { [string]: any } = {}
	for name, value in stub do
		hostFields[name] = Host[name]
		Host[name] = value
	end
	fieldEnv.tern = { ui = { node = function(kind: string, props: any): any return { k = kind, p = props } end } }

	local ok, err = pcall(function()
		local toasts: { string } = {}
		local cx: any = { cwd = "/reader" }
		function cx:render() end
		function cx:toast(_kind: string, title: string) table.insert(toasts, title) end
		function cx:open() end
		function cx:frame() end
		local copied: string? = nil
		function cx:copy(text: string) copied = text end
		local b: any = Block.init(cx, { "fixture=cases" }, nil)
		local function press(name: string, shift: boolean?, meta: boolean?)
			Block.key(b, { name = name, shift = shift or false, meta = meta or false, ctrl = false, alt = false } :: any, cx)
		end
		local KEY = "acme/api#109"
		Block.event(b, { ev = "action", act = "hub-open", value = KEY } :: any, cx)
		assert(b.pages.shown ~= nil, "the Ready card opens its page in the hub")
		local page = b.pages.list[#b.pages.list].page.page
		assert(page ~= nil, "the sample page loads: " .. tostring(b.pages.list[#b.pages.list].page.notice and b.pages.list[#b.pages.list].page.notice.text))
		local button = "main.page.header.status.actions"

		press("p", true)
		assert(page.actionsCursor == 1 and b.s.mode == "board", "⇧P opens the page's Actions menu, not a hub menu")
		local menu = overlays(Block.view(b).layer)
		assert(#menu == 1 and menu[1].p.anchor.node == button, "under the page's Actions button")
		local rows = table.concat(texts(menu[1]), "|")
		assert(rows == "Merge|Mark all reviewed|Copy link|Open on GitHub|Close pull request", rows)

		press("x")
		assert(page.actionsCursor == nil, "a row's letter closes the menu")
		assert(b.s.confirm and b.s.confirm.kind == "close" and b.s.mode == "confirm", "X runs Close, which asks first")
		local ask = overlays(Block.view(b).layer)
		assert(#ask == 1 and ask[1].p.anchor.node == button and table.find(texts(ask[1]), "Close #109?") ~= nil, "Close #109? under the Actions button")

		press("enter", false, true)
		assert(toasts[#toasts] == "The sample board doesn't close pull requests", tostring(toasts[#toasts]))
		assert(b.s.confirm == nil and b.s.mode == "board" and b.pages.shown ~= nil, "the page stays")

		-- A click on a row runs it as its letter does; Copy link is the card's copy.
		Block.event(b, { ev = "action", act = "toggle-actions" } :: any, cx)
		assert(page.actionsCursor == 1, "a click on Actions opens the menu")
		Block.event(b, { ev = "action", act = "actions-run", value = "3" } :: any, cx)
		assert(page.actionsCursor == nil and toasts[#toasts] == "Copied link" and copied ~= nil and string.find(copied, "https://", 1, true) ~= nil, tostring(copied))

		-- j and ⏎ run the highlighted row; A in the menu marks every file reviewed, and its label flips.
		press("p", true)
		press("j")
		assert(page.actionsCursor == 2, "j moves")
		press("enter")
		assert(page.actionsCursor == nil and Review.counts(page.review).filesReviewed == 1, "⏎ runs Mark all reviewed")
		press("p", true)
		rows = table.concat(texts(overlays(Block.view(b).layer)[1]), "|")
		assert(string.find(rows, "Unmark all reviewed", 1, true) ~= nil, rows)
		press("a")
		assert(Review.counts(page.review).filesReviewed == 0, "A in the menu runs it too")
		press("p", true)
		rows = table.concat(texts(overlays(Block.view(b).layer)[1]), "|")
		assert(string.find(rows, "|Mark all reviewed|", 1, true) ~= nil, "A unmarks them again: " .. rows)

		-- Esc closes the menu, then the question, and only then leaves the page.
		press("escape")
		assert(page.actionsCursor == nil and b.pages.shown ~= nil, "Esc closes the menu, not the page")
		press("p", true)
		press("x")
		assert(b.s.confirm and b.s.confirm.kind == "close", "X in the menu chooses Close")
		press("escape")
		assert(b.s.confirm == nil and b.pages.shown ~= nil, "Esc cancels the question, not the page")

		-- `v` opens the reviewers and checks under the page's status marks; its keys are the hub's until `v` closes it.
		press("v")
		assert(b.s.mode == "checks" and b.s.checks and b.s.checks.key == KEY and b.s.checks.from == "page", "v opens the popover on the page's PR")
		local status = overlays(Block.view(b).layer)
		assert(#status == 1 and status[1].p.anchor.node == "main.page.header.status.marks", "under the page's status marks")
		local said = texts(status[1])
		assert(table.find(said, "Reviewers") ~= nil and table.find(said, "alice") ~= nil and table.find(said, "Approved · 1d") ~= nil, table.concat(said, "|"))
		press("j")
		assert(b.s.mode == "checks", "j is the popover's")
		press("v")
		assert(b.s.checks == nil and b.s.mode == "board" and b.pages.shown ~= nil, "v closes it and the page stays")
		Block.event(b, { ev = "action", act = "hub-checks" } :: any, cx)
		assert(b.s.checks and b.s.checks.from == "page", "a click on a mark opens it too")
		Block.event(b, { ev = "action", act = "checks-close" } :: any, cx)
		assert(b.s.checks == nil, "a click outside closes it")

		press("escape")
		assert(b.pages.shown == nil, "then Esc goes back to the board")
	end)
	for name in stub do Host[name] = hostFields[name] end
	fieldEnv.tern = hostField
	if not ok then error(err, 0) end
end
