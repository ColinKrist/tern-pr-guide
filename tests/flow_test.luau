--!strict
-- The before/after diagram's parsing: a stage's tone comes from its change and which sides it has,
-- and the Check line keeps pointing at the stage the guide meant when unusable stages are dropped.
local Guide = require("../src/guide")
local Pr = require("../src/pr")

local function pr(): Pr.PR
	local rows: { Pr.Row } = { { kind = "hunk", oldStart = 1, newStart = 1 } :: Pr.Hunk, { kind = "add", text = "x", new = 1 } :: Pr.Line }
	return {
		repo = "acme/api", number = 1, title = "t", body = "", url = "", author = "a", baseRef = "main", head = "abc",
		files = { { path = "a.ts", status = "modified", adds = 1, dels = 0, rows = rows } },
	}
end

local function flowOf(flow: any): Guide.Flow?
	local raw = {
		schema = 1, overview = "o", flow = flow,
		changes = {
			{ title = "one", why = "w", steps = { { file = "a.ts", from = 1, to = 1, title = "s", note = "n" } } },
			{ title = "two", why = "w", steps = { { file = "a.ts", from = 1, to = 1, title = "s", note = "n" } } },
		},
	}
	local guide = Guide.parse(raw, pr())
	assert(guide, "guide parses")
	return guide.flow
end

return function()
	local flow = flowOf({
		title = "Run",
		stages = {
			{ label = "Start", after = "start()" },
			"not a stage",
			{ label = "Same name", before = "launch()", after = "launch()", change = 1 },
			{ label = "New", after = "check()", change = 2 },
			{ label = "Gone", before = "refuse()", change = 1 },
		},
		check = { text = "Old tasks keep their copy.", stage = 4 },
	})
	assert(flow, "flow parses")
	assert(#flow.stages == 4, "the malformed stage is dropped")
	assert(flow.stages[1].tone == nil, "no change: unchanged")
	assert(flow.stages[2].tone == "changed", "a change with both sides is changed even when the names match")
	assert(flow.stages[3].tone == "added", "a change with only after is added")
	assert(flow.stages[4].tone == "removed", "a change with only before is removed")
	assert(flow.checkStage == 3, "check.stage 4 follows its stage to place 3 after the drop")

	assert(flowOf({ title = "x", stages = { { label = "a", after = "a()" }, { label = "b", after = "b()" } } }) == nil,
		"a diagram with nothing changed is dropped")
	assert(flowOf({ title = "x", rows = { { { text = "a()" } } } }) == nil, "the old rows format shows no diagram")
end
