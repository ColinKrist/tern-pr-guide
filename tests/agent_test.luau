--!strict
-- The reader's saved picks for the two passes, the command each pass runs, and a run's passes.
local Agent = require("../src/agent")

local OMP: Agent.Defaults = { review = { model = "anthropic/opus-5", effort = "high" }, explain = { model = "openai/luna", effort = "medium" } }

local CONFIG = [[
theme: dark
modelRoles:
  smol: openai-codex/gpt-5.6-luna:low
  review: "openai-codex/gpt-6.1-sol:xhigh"  # the strong one
  default: openai-codex/gpt-5.6-luna:high
task:
  smol: not/a-role
]]

-- OMP's own roles stand in for what the reader never picked; the explanation never takes the
-- review role's effort.
local function defaults()
	local all = Agent.defaults(CONFIG)
	assert(all.review and all.review.model == "openai-codex/gpt-6.1-sol" and all.review.effort == "xhigh")
	assert(all.explain and all.explain.model == "openai-codex/gpt-5.6-luna" and all.explain.effort == "low", "smol with its own effort")

	local smolNoEffort = Agent.defaults("modelRoles:\n  smol: openai/luna\n  review: openai/sol:xhigh\n")
	assert(smolNoEffort.explain and smolNoEffort.explain.model == "openai/luna" and smolNoEffort.explain.effort == "medium")

	local defaultOnly = Agent.defaults("modelRoles:\n  default: openai/sol:xhigh\n")
	assert(defaultOnly.review and defaultOnly.review.effort == "xhigh", "the review falls back to the default role")
	assert(defaultOnly.explain and defaultOnly.explain.model == "openai/sol" and defaultOnly.explain.effort == "medium", "default at medium, not its xhigh")

	local reviewOnly = Agent.defaults("modelRoles:\n  review: openai/sol:xhigh\n")
	assert(reviewOnly.explain == nil)
	local fromReview = Agent.picks(nil, reviewOnly)
	assert(fromReview and fromReview.explain.model == "openai/sol" and fromReview.explain.effort == "medium", "the review model at medium, never xhigh")

	local none = Agent.defaults("")
	assert(none.review == nil and none.explain == nil)
end

local function picks()
	local none = Agent.picks(nil, {})
	assert(none == nil, "no saved model and no OMP model is no agent")

	local fresh = Agent.picks(nil, OMP)
	assert(fresh, "OMP's review model stands in")
	assert(fresh.model == "anthropic/opus-5" and fresh.effort == "high")
	assert(fresh.explain.model == "openai/luna" and fresh.explain.effort == "medium" and not fresh.explainPicked, "OMP's fast model explains until one is picked")
	assert(fresh.review == true, "the review is on by default")
	assert(fresh.lens == "Balanced")

	-- A review model the reader picked doesn't decide the explanation's.
	local old = Agent.picks({ model = "openai/gpt-6", effort = "low", lens = "Security" }, OMP)
	assert(old and old.model == "openai/gpt-6" and old.explain.model == "openai/luna" and old.explain.effort == "medium")
	assert(old.review == true and old.lens == "Security")

	local off = Agent.picks({ model = "openai/gpt-6", explainModel = "anthropic/haiku-4", explainEffort = "low", review = false }, OMP)
	assert(off and off.explain.model == "anthropic/haiku-4" and off.explain.effort == "low" and off.explainPicked and off.review == false, "a picked model wins")
	local noEffort = Agent.picks({ model = "openai/gpt-6", effort = "high", explainModel = "local/tiny" }, {})
	assert(noEffort and noEffort.explain.effort == nil, "an explanation model saved without effort keeps none")

	-- What is saved reads back the same.
	local agent = Agent.new("/omp", "/bin", off :: Agent.Picks)
	agent.lens = "Architecture"
	local back = Agent.picks(Agent.saved(agent), OMP)
	assert(back and back.model == "openai/gpt-6" and back.explain.model == "anthropic/haiku-4" and back.explain.effort == "low")
	assert(back.review == false and back.lens == "Architecture")

	-- A default is never saved as a pick, so a later OMP change still reaches it.
	local saved = Agent.saved(Agent.new("/omp", "/bin", fresh :: Agent.Picks))
	assert(saved.explainModel == nil and saved.explainEffort == nil)
end

local function commands()
	local agent = Agent.new("/omp", "/bin", Agent.picks({ model = "a/strong", effort = "high", explainModel = "a/fast", explainEffort = "low" }, {}) :: Agent.Picks)
	local explain = table.concat(Agent.argv(agent, "explain", "/tmp/run/explain.md", "/tmp/run/diff.txt"), " ")
	assert(explain == "/omp -p --no-session --no-skills --no-rules --no-extensions --no-title --tools=read,grep,bash --model a/fast --thinking low @/tmp/run/explain.md @/tmp/run/diff.txt Follow the attached instructions exactly.", explain)
	local review = table.concat(Agent.argv(agent, "review", "/tmp/run/review.md", "/tmp/run/diff.txt"), " ")
	assert(review == "/omp -p --model a/strong --thinking high Read /tmp/run/review.md and follow it exactly.", review)
	agent.explain = { model = "a/plain", effort = nil }
	local plain = table.concat(Agent.argv(agent, "explain", "/tmp/run/explain.md", "/tmp/run/diff.txt"), " ")
	assert(not string.find(plain, "--thinking", 1, true) and string.find(plain, "--model a/plain @", 1, true), "a model without effort gets no --thinking")
end

-- The explanation's reply is the guide, bare or in a fence.
local function replies()
	assert(Agent.replyJson('\n{ "schema": 1 }\n') == '{ "schema": 1 }')
	assert(Agent.replyJson('```json\n{ "schema": 1 }\n```\n') == '{ "schema": 1 }')
	assert(Agent.replyJson('Here it is:\n```\n{\n  "a": "x"\n}\n```') == '{\n  "a": "x"\n}')
	assert(Agent.replyJson("  ") == "")
end

local function runs()
	local agent = Agent.new("/omp", "/bin", Agent.picks(nil, OMP) :: Agent.Picks)
	local run = Agent.idle(agent)
	assert(not Agent.busy(run))
	run.error = "old failure"
	Agent.start(run, { explain = 60, review = 200 })
	assert(run.explaining and run.reviewing and Agent.busy(run) and run.error == nil and run.expected.review == 200)
	run.explaining = false
	assert(Agent.busy(run), "busy while the review is still going")
	run.reviewing = false
	assert(not Agent.busy(run))

	agent.review = false
	Agent.start(run, { explain = 60, review = 200 })
	assert(run.explaining and not run.reviewing, "with the review off only the explanation runs")
end

-- Teaching is no longer built in: a reader who saved it reviews through Balanced, unless they wrote
-- their own Teaching lens.
local function retiredLens()
	local Lens = require("../src/lens")
	local builtIn = { "# Balanced\n\nThe comments worth making.\n", "# Security\n\nLike an attacker.\n\nLook for abuse.\n" }
	local agent = Agent.new("/omp", "/bin", Agent.picks({ model = "a/b", lens = "Teaching" }, {}) :: Agent.Picks)
	agent.lenses = Lens.assemble(builtIn, {})
	assert(agent.lens == "Teaching" and Agent.currentLens(agent).name == "Balanced", "a saved Teaching falls back to Balanced")
	agent.lenses = Lens.assemble(builtIn, { "# Teaching\n\nMine.\n\nExplain gently.\n" })
	assert(Agent.currentLens(agent).name == "Teaching", "the reader's own Teaching lens still applies")
end

return function()
	retiredLens()
	defaults()
	picks()
	commands()
	replies()
	runs()
end
