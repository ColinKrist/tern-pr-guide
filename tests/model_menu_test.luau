--!strict
-- The model and lens menu: its Explanation and Review slots and Tab between them, on the review page
-- and in the PR hub's Settings, the header's status row around them, and the AI row that offers Generate AI guide and
-- Generate LLM review.
local Agent = require("../src/agent")
local Fields = require("../src/text-field")
local Guide = require("../src/guide")
local Keys = require("../src/keys")
local ModelBox = require("../src/model-box")
local Pr = require("../src/pr")
local State = require("../src/state")

local function page(): State.State
	local rows: { Pr.Row } = { { kind = "hunk", oldStart = 1, newStart = 1 } :: Pr.Hunk, { kind = "add", text = "x", new = 1 } :: Pr.Line }
	local p: Pr.PR = { repo = "acme/api", number = 7, title = "t", body = "", url = "", author = "a", createdAt = "", baseRef = "main", head = "abc",
		files = { { path = "a.ts", status = "modified", adds = 1, dels = 0, rows = rows } } }
	return State.new(p, Guide.defaultGuide(p), { root = "main" })
end

local function agent(): Agent.Agent
	local a = Agent.new("/omp", "/bin", Agent.picks({ model = "anthropic/opus-5", effort = "high" }, {}) :: Agent.Picks)
	a.models = {
		{ selector = "anthropic/haiku-4", name = "Haiku 4", efforts = { "low", "high" } },
		{ selector = "anthropic/opus-5", name = "Opus 5", efforts = { "low", "high", "max" } },
	}
	return a
end

local function names(box: ModelBox.ModelBox, a: Agent.Agent): string
	local out = {}
	for _, model in ModelBox.choices(box, a) do table.insert(out, model.name) end
	return table.concat(out, ",")
end

local function key(name: string, shift: boolean?): Key
	return { name = name, shift = shift or false, meta = false, ctrl = false, alt = false } :: any
end

-- Every text a node tree draws, joined.
local function texts(node: any, out: { string }?): string
	local acc = out or {}
	if node.p and type(node.p.text) == "string" then table.insert(acc, node.p.text) end
	if node.p and type(node.p.aria) == "string" then table.insert(acc, "@" .. node.p.aria) end
	if node.p and node.p.keys then table.insert(acc, "[" .. table.concat(node.p.keys, "+") .. "]") end
	for _, child in node.c or {} do texts(child, acc) end
	return table.concat(acc, "|")
end

-- The menu and the header's AI row as they draw.
local function drawn()
	local ModelPanel = require("../src/view/model-panel")
	local Header = require("../src/view/header")
	local fieldEnv: any = getfenv(require("../src/view/ui").field)
	local host = fieldEnv.tern
	fieldEnv.tern = { ui = { node = function(kind: string, props: any): any return { k = kind, p = props } end } }
	local ok, err = pcall(function()
		local s, a = page(), agent()
		a.lenses = { { name = "Balanced", description = "The comments worth making.", instructions = "" } }
		s.models = ModelBox.open(a, "explain")
		local explain = texts(ModelPanel.view(s.models :: ModelBox.ModelBox, a, "anchor", false))
		assert(string.find(explain, "Explains what the PR changes, step by step.", 1, true) and string.find(explain, "[tab]", 1, true), explain)
		assert(not string.find(explain, "Edit lenses", 1, true), "Explanation has no lenses")
		s.models = ModelBox.open(a, "review")
		local review = texts(ModelPanel.view(s.models :: ModelBox.ModelBox, a, "anchor", false))
		assert(string.find(review, "anthropic|Haiku 4||Opus 5", 1, true) and not string.find(review, "Edit lenses", 1, true), review)
		assert(not string.find(review, "Off", 1, true), "Review has no Off row: " .. review)
		s.models = ModelBox.open(a, "lens")
		local lens = texts(ModelPanel.view(s.models :: ModelBox.ModelBox, a, "anchor", false))
		assert(string.find(lens, "Balanced|The comments worth making.", 1, true) and string.find(lens, "Edit lenses…|[ctrl+E]", 1, true), "Lens lists each lens with its description: " .. lens)
		assert(not string.find(lens, "Haiku 4", 1, true), "and no models: " .. lens)

		local motion = { born = {}, next = {}, booted = true, animate = false }
		s.models = nil
		a.explain = { model = "anthropic/haiku-4", effort = "low" }
		s.ai = Agent.idle(a)
		local idle = texts(Header.view(s, motion))
		assert(string.find(idle, "@Open on GitHub|[g]|@Mark all reviewed|[m]|@Settings|[shift+M]|Generate AI guide|[shift+G]|Generate LLM review|[shift+R]", 1, true), idle)
		assert(not string.find(idle, "haiku-4", 1, true), "the models are in Settings, not the header: " .. idle)
		assert(not string.find(idle, "Reviewers and checks", 1, true), "outside the hub the row has no status marks: " .. idle)
		s.hosted = { fixes = false, pr = true, prOpen = false, status = { reviews = { kind = "changes" }, checks = { failing = 1, pending = 2, passed = 14 }, open = false } }
		local hosted = texts(Header.view(s, motion))
		assert(string.find(hosted, "a opened|·|@Reviewers and checks|Changes requested|·|@Reviewers and checks|1|·||2 pending|·|14 passed|·|", 1, true), "the PR's marks follow who opened it: " .. hosted)
		assert(string.find(hosted, "@Settings|[shift+M]|@Pull request|Pull request|Generate", 1, true), "the Pull request button comes last, without its key: " .. hosted)
		s.hosted = nil
		local run = s.ai :: Agent.Run
		Agent.start(run, "explain", 60)
		local explaining = texts(Header.view(s, motion))
		assert(string.find(explaining, "E|x|p|l|a|i|n", 1, true) and not string.find(explaining, "Generate LLM review", 1, true), "the explanation writes its phrase in: " .. explaining)
		run.explaining = false
		Agent.start(run, "review", 180)
		local reviewing = texts(Header.view(s, motion))
		assert(string.find(reviewing, "Generate AI guide|[shift+G]|Reviewing for issues…|0:00", 1, true), "the review's quiet progress takes its button's place: " .. reviewing)
		assert(not string.find(reviewing, "Generate LLM review", 1, true) and not string.find(reviewing, "Settings", 1, true), "no Generate LLM review button or Settings while it runs: " .. reviewing)
		s.review.guide.guided = true
		local guided = texts(Header.view(s, motion))
		assert(string.find(guided, "Reviewing for issues…|0:00", 1, true) and not string.find(guided, "Generate AI guide", 1, true), "over a guide, the review shows in the same row: " .. guided)
		run.reviewing = false
		local offered = texts(Header.view(s, motion))
		assert(string.find(offered, "@Settings|[shift+M]", 1, true) and string.find(offered, "Generate LLM review|[shift+R]", 1, true) and not string.find(offered, "Generate AI guide", 1, true), "a guided page offers Settings and Generate LLM review: " .. offered)
		s.review.guide.guided = false

		s.models = ModelBox.open(a, "review")
		local box = s.models :: ModelBox.ModelBox
		box.top = 2
		local scrolled = texts(ModelPanel.view(box, a, "anchor", false))
		assert(string.find(scrolled, "↑  1 more|anthropic|Opus 5", 1, true) and not string.find(scrolled, "Haiku 4", 1, true), "a scrolled list starts under a row offering the rest: " .. scrolled)
		s.models = nil
	end)
	fieldEnv.tern = host
	if not ok then error(err, 0) end
end

return function()
	drawn()
	local s, a = page(), agent()

	s.models = ModelBox.open(a, "explain")
	local box = s.models :: ModelBox.ModelBox
	assert(names(box, a) == "Haiku 4,Opus 5", names(box, a))
	assert(box.selected == 2 and box.effort == "medium", "the explanation starts on the review model it defaults to, at medium")
	box.selected, box.effort = 1, "low"
	assert(ModelBox.choose(box, a))
	assert(a.explain.model == "anthropic/haiku-4" and a.explain.effort == "low" and a.explainPicked, "picking on Explanation sets the explanation")
	assert(a.model == "anthropic/opus-5" and a.effort == "high", "and leaves the review model")

	assert(Keys.action(s, key("tab")).act == "models-slot" and Keys.action(s, key("tab")).value == "review", "Tab goes to Review")
	s.models = ModelBox.open(a, "review")
	box = s.models :: ModelBox.ModelBox
	assert(Keys.action(s, key("tab")).value == "lens", "Tab goes on to Lens")
	assert(names(box, a) == "Haiku 4,Opus 5", "Review lists the same models: " .. names(box, a))
	assert(box.selected == 2, "Review highlights its model")
	box.selected = 1
	assert(ModelBox.choose(box, a))
	assert(a.model == "anthropic/haiku-4" and a.effort == "high", "picking on Review sets the review model")
	assert(a.explain.model == "anthropic/haiku-4" and a.explain.effort == "low", "and leaves the explanation")
	box.field = Fields.create("nothing")
	assert(not ModelBox.choose(box, a), "a filter that matches nothing picks nothing")

	-- The Lens slot: it highlights the lens in use, arrows move, choosing sets the lens and nothing else,
	-- and Tab wraps back to Explanation.
	a.lenses = {
		{ name = "Balanced", description = "", instructions = "" },
		{ name = "Security", description = "", instructions = "" },
		{ name = "Quick skim", description = "", instructions = "" },
	}
	a.lens = "Security"
	s.models = ModelBox.open(a, "lens")
	box = s.models :: ModelBox.ModelBox
	assert(box.selected == 2, "Lens highlights the lens in use")
	assert(Keys.action(s, key("tab")).value == "explain", "Tab wraps to Explanation")
	assert(Keys.action(s, key("right")).act == "models-effort", "← → stay the effort keys")
	ModelBox.stepEffort(box, a, 1)
	ModelBox.move(box, a, 5)
	assert(box.selected == 3, "arrows stop at the last lens")
	assert(ModelBox.choose(box, a) and a.lens == "Quick skim" and a.model == "anthropic/haiku-4", "choosing sets the lens and leaves the models")
	box.field = Fields.create("sec")
	box.selected = 1
	assert(ModelBox.choose(box, a) and a.lens == "Security", "the filter narrows the lenses")
	s.models = nil
	assert(Keys.action(s, key("l", true)).act == "toggle-lenses", "⇧L opens the menu on Lens")
	local file = Keys.action(s, key("f"))
	assert(file and file.act == "mark-file" and file.value == "a.ts", "f marks the whole file reviewed")
	assert(Keys.action(s, key("v")) == nil, "v is the hub's, so a page alone leaves it be")

	-- Arrowing down a list where every model has its own provider heading keeps the highlighted row
	-- within the lines the list fits, headings and the "more" row counted.
	a.models = {}
	for n = 1, 12 do table.insert(a.models, { selector = "p" .. n .. "/m", name = "M" .. n, efforts = {} }) end
	box = ModelBox.open(a, "review")
	box.selected, box.top = 1, 1
	for _ = 1, 12 do ModelBox.move(box, a, 1) end
	assert(box.selected == 12, "the last model is highlighted")
	local lines = (if box.top > 1 then 1 else 0) + 2 * (box.selected - box.top + 1)
	assert(lines <= 8, "the highlighted row is in view: " .. lines .. " lines from top " .. box.top)
end
