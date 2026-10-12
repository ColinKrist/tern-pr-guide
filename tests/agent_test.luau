--!strict
-- The reader's saved picks for the two passes, the command each pass runs, and a run's passes.
local Agent = require("../src/agent")

local OMP: Agent.Choice = { model = "anthropic/opus-5", effort = "high" }

local function picks()
	local none = Agent.picks(nil, nil)
	assert(none == nil, "no saved model and no OMP model is no agent")

	local fresh = Agent.picks(nil, OMP)
	assert(fresh, "OMP's review model stands in")
	assert(fresh.model == "anthropic/opus-5" and fresh.effort == "high")
	assert(fresh.explain.model == "anthropic/opus-5" and fresh.explain.effort == "high", "the explanation uses the review model until picked")
	assert(fresh.review == true, "the review is on by default")
	assert(fresh.lens == "Balanced")

	-- A choice saved before the explanation had its own model.
	local old = Agent.picks({ model = "openai/gpt-6", effort = "low", lens = "Security" }, OMP)
	assert(old and old.model == "openai/gpt-6" and old.explain.model == "openai/gpt-6" and old.explain.effort == "low")
	assert(old.review == true and old.lens == "Security")

	local off = Agent.picks({ model = "openai/gpt-6", explainModel = "anthropic/haiku-4", explainEffort = "low", review = false }, nil)
	assert(off and off.explain.model == "anthropic/haiku-4" and off.explain.effort == "low" and off.review == false)
	local noEffort = Agent.picks({ model = "openai/gpt-6", effort = "high", explainModel = "local/tiny" }, nil)
	assert(noEffort and noEffort.explain.effort == nil, "an explanation model saved without effort keeps none")

	-- What is saved reads back the same.
	local agent = Agent.new("/omp", "/bin", off :: Agent.Picks)
	agent.lens = "Architecture"
	local back = Agent.picks(Agent.saved(agent), OMP)
	assert(back and back.model == "openai/gpt-6" and back.explain.model == "anthropic/haiku-4" and back.explain.effort == "low")
	assert(back.review == false and back.lens == "Architecture")
end

local function commands()
	local agent = Agent.new("/omp", "/bin", Agent.picks({ model = "a/strong", effort = "high", explainModel = "a/fast", explainEffort = "low" }, nil) :: Agent.Picks)
	local explain = Agent.argv(agent, "explain", "/tmp/explain.md")
	assert(explain[4] == "a/fast" and explain[6] == "low", table.concat(explain, " "))
	local review = Agent.argv(agent, "review", "/tmp/review.md")
	assert(review[4] == "a/strong" and review[6] == "high", table.concat(review, " "))
	agent.explain = { model = "a/plain", effort = nil }
	local plain = Agent.argv(agent, "explain", "/tmp/explain.md")
	assert(plain[4] == "a/plain" and plain[5] ~= "--thinking", "a model without effort gets no --thinking")
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
	local agent = Agent.new("/omp", "/bin", Agent.picks({ model = "a/b", lens = "Teaching" }, nil) :: Agent.Picks)
	agent.lenses = Lens.assemble(builtIn, {})
	assert(agent.lens == "Teaching" and Agent.currentLens(agent).name == "Balanced", "a saved Teaching falls back to Balanced")
	agent.lenses = Lens.assemble(builtIn, { "# Teaching\n\nMine.\n\nExplain gently.\n" })
	assert(Agent.currentLens(agent).name == "Teaching", "the reader's own Teaching lens still applies")
end

return function()
	retiredLens()
	picks()
	commands()
	runs()
end
