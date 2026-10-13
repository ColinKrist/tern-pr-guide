--!strict
-- A PR's page in the hub offers the PR's pull request actions: ⇧P opens the Pull request menu under the page's button,
-- Close asks "Close #n?" in place, ⌘⏎ answers it (a sample board only says it doesn't close), and Esc closes the menu
-- or the question before it leaves the page. `v` and a click on its status marks open its reviewers and checks.
local Block: any = require("../src/hub/block")
local Host: any = require("../src/host")
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
	if node.p and type(node.p.text) == "string" then table.insert(list, node.p.text) end
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
		-- The page's sample PR, one file and no guide, so the page opens as a notice: the hub's keys and layer are what this
		-- test reads, and they are the same over any page.
		fs = { read = function(path: string): string? return if string.find(path, "fixtures/pr-", 1, true) then "SAMPLE" else nil end },
		json = { decode = function(text: string): any
			if text ~= "SAMPLE" then return nil end
			return { pr = { repo = "acme/api", number = 350, title = "Sample", body = "", url = "", author = "", createdAt = "", baseRef = "main", head = "abc" }, files = {} }
		end, encode = function(): string return "" end },
		getenv = function(): string? return nil end,
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
		local b: any = Block.init(cx, { "fixture=cases" }, nil)
		local function press(name: string, shift: boolean?, meta: boolean?)
			Block.key(b, { name = name, shift = shift or false, meta = meta or false, ctrl = false, alt = false } :: any, cx)
		end
		local KEY = "acme/api#109"
		Block.event(b, { ev = "action", act = "hub-open", value = KEY } :: any, cx)
		assert(b.pages.shown ~= nil, "the Ready card opens its page in the hub")
		local button = "main.page.header.status.pr"

		press("p", true)
		assert(b.s.menu == "pr" and b.s.mode == "menu", "⇧P opens the Pull request menu")
		local menu = overlays(Block.view(b).layer)
		assert(#menu == 1 and menu[1].p.anchor.node == button, "under the page's button")
		assert(table.find(texts(menu[1]), "Close pull request") ~= nil and table.find(texts(menu[1]), "Merge") ~= nil)

		press("j")
		press("enter")
		assert(b.s.confirm and b.s.confirm.kind == "close" and b.s.mode == "confirm", "⏎ on Close asks first")
		local ask = overlays(Block.view(b).layer)
		assert(#ask == 1 and ask[1].p.anchor.node == button and table.find(texts(ask[1]), "Close #109?") ~= nil, "Close #109? under the button")

		press("enter", false, true)
		assert(toasts[#toasts] == "The sample board doesn't close pull requests", tostring(toasts[#toasts]))
		assert(b.s.confirm == nil and b.s.mode == "board" and b.pages.shown ~= nil, "the page stays")

		-- Esc closes the menu, then the question, and only then leaves the page.
		press("p", true)
		press("escape")
		assert(b.s.menu == nil and b.pages.shown ~= nil, "Esc closes the menu, not the page")
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
