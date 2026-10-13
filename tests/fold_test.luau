--!strict
-- Opening a fold on the hub scrolls its header to the top of the board; closing one doesn't scroll.
local Block: any = require("../src/hub/block")
local Host: any = require("../src/host")
local Ui: any = require("../src/view/ui")
local Paths = require("../src/view/hub/paths")

-- The node the board draws at `path`. parts[1] is "main", the block's root: the view's own outer node.
local function nodeAt(root: any, path: string): any
	local node = root
	local parts = string.split(path, ".")
	for i = 2, #parts do
		local found = nil
		for _, child in node.c or {} do
			if child.p and child.p.key == parts[i] then found = child end
		end
		if not found then return nil end
		node = found
	end
	return node
end

return function()
	local fieldEnv: any = getfenv(Ui.field)
	local hostField = fieldEnv.tern
	local stub: { [string]: any } = {
		timer = function(_ms: number, fn: () -> ()): any
			fn()
			return { cancel = function() end }
		end,
		json = { decode = function(): any return nil end, encode = function(): string return "" end },
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
		local frames: { any } = {}
		local cx: any = { cwd = "/reader" }
		function cx:render() end
		function cx:toast() end
		function cx:open() end
		function cx:frame(ops: { any })
			for _, op in ops do table.insert(frames, op) end
		end
		local b: any = Block.init(cx, { "fixture=cases" }, nil)
		local function press(name: string, shift: boolean?)
			Block.key(b, { name = name, shift = shift or false, meta = false, ctrl = false, alt = false } :: any, cx)
		end
		local function lastFrame(): string
			local op = frames[#frames]
			return if op then table.concat(op, " ") else ""
		end
		-- Your pull requests: R opens Recently merged.
		press("r")
		assert(b.s.folded.merged == false and b.s.folded.recent == true, "R opens Recently merged")
		assert(lastFrame() == "reveal " .. Paths.foldHead("merged") .. " start", lastFrame())
		local merged = nodeAt(Block.view(b).main, Paths.foldHead("merged"))
		assert(merged and string.find(merged.p.class, "gp-hub-foldhead", 1, true), "Recently merged's header is drawn at Paths.foldHead")
		press("r")
		frames = {}
		press("t")
		assert(b.s.tab == "review" and #frames == 0)

		for _, case in { { "a", false, "approved" }, { "t", true, "team" }, { "i", false, "inactive" }, { "r", false, "recent" } } do
			local name, shift, fold = case[1], case[2] :: boolean, case[3]
			local before = #frames
			press(name, shift)
			assert(b.s.folded[fold] == false, fold .. " opens")
			assert(#frames == before + 1 and lastFrame() == "reveal " .. Paths.foldHead(fold) .. " start", fold .. ": " .. lastFrame())
			local head = nodeAt(Block.view(b).main, Paths.foldHead(fold))
			assert(head and string.find(head.p.class, "gp-hub-foldhead", 1, true), fold .. "'s header is drawn at Paths.foldHead")
			press(name, shift)
			assert(b.s.folded[fold] == true and #frames == before + 1, fold .. ": closing doesn't scroll")
		end
	end)
	for name in stub do Host[name] = hostFields[name] end
	fieldEnv.tern = hostField
	if not ok then error(err, 0) end
end
