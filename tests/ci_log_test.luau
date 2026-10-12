--!strict
-- The failed-check log contract and the two CI modules that meet it, each run on recorded output.
local Actions = require("../src/ci/actions")
local Buildkite = require("../src/ci/buildkite")
local Log = require("../src/ci/log")
local Recorded: any = require("../fixtures/hub/ci-logs")

type Call = { argv: string, env: { [string]: string }? }

-- A runner that answers from `outputs` by command, or with `fail` for every command; records each call.
local function fakeRun(outputs: { [string]: string }, fail: Log.Out?): (Log.Run, { Call })
	local calls: { Call } = {}
	local function run(argv: { string }, opts: { timeout_ms: number?, env: { [string]: string }? }, done: (out: Log.Out) -> ())
		local command = table.concat(argv, " ")
		table.insert(calls, { argv = command, env = opts.env })
		if fail then return done(fail) end
		local stdout = outputs[command]
		if stdout then return done({ status = 0, stdout = stdout, stderr = "", timed_out = false }) end
		done({ status = 1, stdout = "", stderr = "unexpected command: " .. command, timed_out = false })
	end
	return run, calls
end

-- The one JSON document the Buildkite fixture prints, already decoded: plain Luau has no JSON reader.
local function decode(text: string): any
	assert(text == Recorded.buildkiteFailures, "decode got other text")
	return {
		failures = { { build = "acme/web/429", id = "0190046e-e199-453b-a302-a21a4d649d31", name = ":jest: Unit tests", state = "failed" } },
	}
end

local function read(provider: Log.Provider, check: Log.Check, repo: string): (Log.Log?, string?)
	local log, err, answered = nil, nil, false
	provider.read(check, repo, function(l, e)
		log, err, answered = l, e, true
	end)
	assert(answered, "read answered")
	return log, err
end

local function has(lines: { string }, text: string): boolean
	for _, line in lines do
		if line == text then return true end
	end
	return false
end

local ACTIONS_CHECK: Log.Check = { name = "build", url = "https://github.com/acme/web/actions/runs/902/job/1", runId = 902 }
local BUILD_CHECK: Log.Check = { name = "buildkite/web", url = "https://buildkite.com/acme/web/builds/429", runId = nil }
local JOB_CHECK: Log.Check = { name = "Unit tests", url = "https://buildkite.com/acme/web/builds/429#0190046e-e199-453b-a302-a21a4d649d31", runId = nil }
local OTHER_CHECK: Log.Check = { name = "deploy/preview", url = "https://vercel.com/acme/web/abc", runId = nil }

return function()
	-- Each module claims only its own checks; anything else has no log to read.
	local run = fakeRun(Recorded.outputs)
	local actions, buildkite = Actions.provider(run), Buildkite.provider(run, decode)
	assert(actions.owns(ACTIONS_CHECK) and not actions.owns(BUILD_CHECK) and not actions.owns(OTHER_CHECK))
	assert(buildkite.owns(BUILD_CHECK) and buildkite.owns(JOB_CHECK) and not buildkite.owns(ACTIONS_CHECK) and not buildkite.owns(OTHER_CHECK))
	local providers = { buildkite, actions }
	assert(Log.providerFor(providers, ACTIONS_CHECK) == actions and Log.providerFor(providers, BUILD_CHECK) == buildkite)
	assert(Log.providerFor(providers, OTHER_CHECK) == nil)

	-- Actions: one job's failed steps, without timestamps, colors or group markers, cut to the lines around the error.
	assert(table.concat(Actions.command("acme/web", ACTIONS_CHECK), " ") == "gh run view 902 --repo acme/web --log-failed --job 1")
	local log = read(actions, ACTIONS_CHECK, "acme/web") :: Log.Log
	assert(#log.sections == 1 and log.sections[1].title == "fail", "one section per job")
	local lines = log.sections[1].lines
	assert(has(lines, "Process completed with exit code 1.") and has(lines, "Run exit 1") and has(lines, "exit 1"), table.concat(lines, "\n"))
	assert(string.match(lines[1], "^… %d+ lines omitted$"), lines[1])
	for _, line in lines do
		assert(not string.find(line, "##[", 1, true) and not string.find(line, "\27", 1, true) and not string.match(line, "^%d%d%d%d%-"), line)
	end
	-- A log with no line that reads as an error keeps its tail.
	local quiet = Actions.parse("j\ts\t2026-10-10T08:46:49.1Z one\nj\ts\t2026-10-10T08:46:49.2Z two\n")
	assert(#quiet.sections == 1 and table.concat(quiet.sections[1].lines, "|") == "one|two")
	local _, actionsErr = read(Actions.provider(fakeRun({}, { status = 1, stdout = "", stderr = "HTTP 404: Not Found\nmore", timed_out = false })), ACTIONS_CHECK, "acme/web")
	assert(actionsErr == "HTTP 404: Not Found", actionsErr)

	-- Buildkite: the build's failed jobs, then each job's log, both asked of the org the link names.
	local bkRun, calls = fakeRun(Recorded.outputs)
	local bkLog = read(Buildkite.provider(bkRun, decode), BUILD_CHECK, "acme/web") :: Log.Log
	assert(#calls == 2 and calls[1].argv == "bk build view acme/web/429 --recursive --json", calls[1].argv)
	assert(calls[2].argv == "bk job log 0190046e-e199-453b-a302-a21a4d649d31 --agent --max-tokens 1500")
	assert(calls[1].env and calls[1].env.BUILDKITE_ORGANIZATION_SLUG == "acme" and calls[2].env and calls[2].env.BUILDKITE_ORGANIZATION_SLUG == "acme")
	assert(#bkLog.sections == 1 and bkLog.sections[1].title == ":jest: Unit tests")
	assert(bkLog.sections[1].lines[1] == "Running commands" and has(bkLog.sections[1].lines, ":jest: Unit tests"), "group markers become plain headings")
	assert(bkLog.sections[1].lines[#bkLog.sections[1].lines] == "🚨 Error: The command exited with status 1", "trailing blank lines dropped")
	-- A link to one job reads that job alone.
	local jobRun, jobCalls = fakeRun(Recorded.outputs)
	local jobLog = read(Buildkite.provider(jobRun, decode), JOB_CHECK, "acme/web") :: Log.Log
	assert(#jobCalls == 1 and jobLog.sections[1].title == "Unit tests")
	assert(Buildkite.build("https://github.com/acme/web/actions/runs/1") == nil)
	-- Failures say why, in words the page can show after "Couldn't read the log:".
	local _, missing = read(Buildkite.provider(fakeRun({}, { status = 127, stdout = "", stderr = "bk: command not found", timed_out = false }), decode), BUILD_CHECK, "acme/web")
	assert(missing == "bk isn't installed or isn't on the PATH (bk: command not found)", missing)
	local _, odd = read(Buildkite.provider(fakeRun(Recorded.outputs), function() return { nope = true } end), BUILD_CHECK, "acme/web")
	assert(odd == "bk returned output this version can't read", odd)

	-- The places a log names in the PR's changed files, each once, a build machine's folder ignored.
	local refs = Log.refs(bkLog, { "src/cart/reprice.ts", "src/cart/reprice.test.ts", "README.md" })
	assert(#refs == 2, #refs)
	assert(refs[1].path == "src/cart/reprice.test.ts" and refs[1].line == 42 and string.find(refs[1].text, "Object.<anonymous>", 1, true))
	assert(refs[2].path == "src/cart/reprice.ts" and refs[2].line == 57)
	assert(#Log.refs({ sections = { { title = "", lines = { "at x (lib/src/cart/reprice.ts:9)" } } } }, { "src/cart/reprice.ts" }) == 1)
	assert(#Log.refs({ sections = { { title = "", lines = { "at x (mysrc/cart/reprice.ts:9)" } } } }, { "src/cart/reprice.ts" }) == 0, "a path ends at a folder boundary")
end
