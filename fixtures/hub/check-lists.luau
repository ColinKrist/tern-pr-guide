--!strict
-- The sample board's check lists, so the checks popover works on `fixture=cases` without GitHub. SYNTHETIC, in the
-- shape `Github.parseCheckList` returns, timed against the cases clock (2026-10-09T12:00:00Z). #111 matches its fixes
-- page (build on Actions and buildkite/web failing), with build running again after a re-run and a deploy queued
-- behind it; #114 has a check running and one skipped; and any other card's list is built from its board counts.
local Checks = require("../../src/hub/checks")
local Model = require("../../src/hub/model")

local M = {}

-- The ISO time `seconds` (under 12 hours) before the cases clock, 2026-10-09T12:00:00Z.
local function ago(seconds: number): string
	local t = 12 * 3600 - seconds
	return string.format("2026-10-09T%02d:%02d:%02dZ", t // 3600, (t % 3600) // 60, t % 60)
end

local function done(name: string, source: string, state: Checks.CheckState, from: number, took: number, url: string?): Checks.CheckRow
	return { name = name, source = source, state = state, startedAt = ago(from), completedAt = ago(from - took), url = url or ("https://github.com/acme/web/actions/runs/900/job/" .. #name) }
end

local function running(name: string, source: string, since: number, url: string?): Checks.CheckRow
	return { name = name, source = source, state = "running", startedAt = ago(since), completedAt = nil, url = url or "https://github.com/acme/web/actions/runs/905/job/1" }
end

local PASSED = { "lint", "unit (node 22)", "unit (node 24)", "storybook", "a11y", "bundle size", "license scan", "codeql", "format" }

M.lists = {
	["acme/web#111"] = { headOid = "head111", rows = {
		running("build", "ci", 72, "https://github.com/acme/web/actions/runs/902/job/1"),
		{ name = "buildkite/web", source = nil, state = "failing", startedAt = nil, completedAt = nil, url = "https://buildkite.com/acme/web/builds/429" },
		done("lint", "ci", "passed", 7200, 38),
		done("typecheck", "ci", "passed", 7200, 64),
		{ name = "deploy-preview", source = "Deploy", state = "queued", startedAt = nil, completedAt = nil, url = "https://github.com/acme/web/actions/runs/906" },
	} },
	["acme/api#114"] = { headOid = "head114", rows = {
		running("e2e (chromium)", "Buildkite", 384, "https://buildkite.com/acme/app/builds/88"),
		done("lint", "CI", "passed", 900, 38),
		done("typecheck", "CI", "passed", 900, 91),
		{ name = "ios build", source = "Mobile", state = "skipped", startedAt = nil, completedAt = nil, url = "https://github.com/acme/api/actions/runs/78" },
	} },
} :: { [string]: Checks.CheckList }

-- The list the sample shows for `pr`: its own, else one built from the board's counts.
function M.forPr(pr: Model.HubPR): Checks.CheckList
	local own = M.lists[pr.key]
	if own then return own end
	local rows: { Checks.CheckRow } = {}
	for i = 1, pr.checks.failing do table.insert(rows, done("test " .. i, "CI", "failing", 3600, 120 + i)) end
	for i = 1, pr.checks.pending do table.insert(rows, running("e2e " .. i, "CI", 300 + i * 40)) end
	for i = 1, pr.checks.passing do table.insert(rows, done(PASSED[(i - 1) % #PASSED + 1], if i % 3 == 0 then "Checks" else "CI", "passed", 3600, 30 + (i * 53) % 400)) end
	return { headOid = pr.headOid, rows = rows }
end

return M
