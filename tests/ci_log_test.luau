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

local function retry(provider: Log.Provider, checks: { Log.Check }): (number?, string?)
	local count, err, answered = nil, nil, false
	provider.retry(checks, "acme/web", function(c, e)
		count, err, answered = c, e, true
	end)
	assert(answered, "retry answered")
	return count, err
end

-- The level of the text line that reads `text`, or nil when no line does.
local function levelOf(lines: { Log.Line }, text: string): Log.Level?
	for _, line in lines do
		if line.kind == "text" and line.text == text then return line.level end
	end
	return nil
end

-- The lines as one string: "level:text" per text line, "gap:N" per gap.
local function show(lines: { Log.Line }): string
	local out: { string } = {}
	for _, line in lines do
		if line.kind == "text" then
			table.insert(out, line.level .. ":" .. line.text)
		else
			table.insert(out, "gap:" .. line.count)
		end
	end
	return table.concat(out, "\n")
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

	-- Each line reads as one level, first rule first; the CI's own markers are dropped from what shows.
	for text, level in {
		["Error: Cannot find module './x'"] = "error", ["src/a.ts(3,1): error TS2304: Cannot find name 'x'."] = "error",
		[" FAIL  src/a.test.ts"] = "error", ["  ● cart › reprices"] = "error", ["E   AssertionError: 1 != 2"] = "error",
		["🚨 Error: The command exited with status 1"] = "error", ["##[error]Process completed with exit code 1."] = "error",
		["--- FAIL: TestReprice (0.01s)"] = "error", ["Traceback (most recent call last):"] = "error",
		["##[group]Run npm test"] = "heading", ["+++ :jest: Unit tests"] = "heading", ["--- Installing"] = "heading",
		["~~~ Running commands"] = "heading", ["$ yarn jest --ci"] = "command", ["##[command]/usr/bin/git log"] = "command",
		["Tests: 1 failed, 211 passed"] = "plain", ["errors: 0"] = "plain", ["Terror is a word"] = "plain", [""] = "plain",
	} :: { [string]: Log.Level } do
		assert(Log.classify(text) == level, text .. " reads as " .. Log.classify(text))
		local line = Log.line(text)
		assert(line.kind == "text" and line.level == level, text)
	end
	local heading = Log.line("##[group]Run npm test")
	assert(heading.kind == "text" and heading.text == "Run npm test")
	local bkHeading = Log.line("+++ :jest: Unit tests")
	assert(bkHeading.kind == "text" and bkHeading.text == ":jest: Unit tests")
	local flagged = Log.line("##[error]Process completed with exit code 1.")
	assert(flagged.kind == "text" and flagged.text == "Process completed with exit code 1.")
	local warned = Log.line("##[warning]Node 16 is deprecated")
	assert(warned.kind == "text" and warned.text == "Node 16 is deprecated" and warned.level == "plain")

	-- Actions: one job's failed steps, without timestamps, colors or group markers, cut to the lines around the error.
	assert(table.concat(Actions.command("acme/web", ACTIONS_CHECK), " ") == "gh run view 902 --repo acme/web --log-failed --job 1")
	local log = read(actions, ACTIONS_CHECK, "acme/web") :: Log.Log
	assert(#log.sections == 1 and log.sections[1].title == "fail", "one section per job")
	local lines = log.sections[1].lines
	assert(levelOf(lines, "Process completed with exit code 1.") == "error" and levelOf(lines, "Run exit 1") == "heading", show(lines))
	assert(levelOf(lines, "exit 1") == "plain" and Log.errors(log.sections[1]) == 1, show(lines))
	-- The runner's setup before the first step is left out, though it is within the window above the error.
	local first, second = lines[1], lines[2]
	assert(first.kind == "gap" and first.count == 44, show(lines))
	assert(second.kind == "text" and second.text == "Run exit 1", show(lines))
	assert(levelOf(lines, "Prepare all required actions") == nil and levelOf(lines, "Complete job name: fail") == nil, "setup is not kept")
	for _, line in lines do
		local text = if line.kind == "text" then line.text else ""
		assert(not string.find(text, "##[", 1, true) and not string.find(text, "\27", 1, true) and not string.match(text, "^%d%d%d%d%-"), text)
	end
	-- An error in the setup is still kept.
	local setup = Actions.parse("j\ts\tError: no space left on device\nj\ts\tsetup\nj\ts\t##[group]Run make\nj\ts\tmake: ok\n")
	assert(show(setup.sections[1].lines) == "error:Error: no space left on device\ngap:1\nheading:Run make\nplain:make: ok", show(setup.sections[1].lines))
	-- A log with no line that reads as an error keeps its tail.
	local quiet = Actions.parse("j\ts\t2026-10-10T08:46:49.1Z one\nj\ts\t2026-10-10T08:46:49.2Z two\n")
	assert(#quiet.sections == 1 and show(quiet.sections[1].lines) == "plain:one\nplain:two", show(quiet.sections[1].lines))
	local _, actionsErr = read(Actions.provider(fakeRun({}, { status = 1, stdout = "", stderr = "HTTP 404: Not Found\nmore", timed_out = false })), ACTIONS_CHECK, "acme/web")
	assert(actionsErr == "HTTP 404: Not Found", actionsErr)

	-- Buildkite: the build's failed jobs, then each job's log, both asked of the org the link names.
	local bkRun, calls = fakeRun(Recorded.outputs)
	local bkLog = read(Buildkite.provider(bkRun, decode), BUILD_CHECK, "acme/web") :: Log.Log
	assert(#calls == 2 and calls[1].argv == "bk build view acme/web/429 --recursive --json", calls[1].argv)
	assert(calls[2].argv == "bk job log 0190046e-e199-453b-a302-a21a4d649d31 --agent --max-tokens 1500")
	assert(calls[1].env and calls[1].env.BUILDKITE_ORGANIZATION_SLUG == "acme" and calls[2].env and calls[2].env.BUILDKITE_ORGANIZATION_SLUG == "acme")
	assert(#bkLog.sections == 1 and bkLog.sections[1].title == ":jest: Unit tests")
	local bkLines = bkLog.sections[1].lines
	assert(show({ table.unpack(bkLines, 1, 4) }) == "heading:Running commands\ncommand:$ yarn jest --ci\ngap:212\nheading::jest: Unit tests", show(bkLines))
	assert(levelOf(bkLines, " FAIL  src/cart/reprice.test.ts") == "error" and levelOf(bkLines, "  ● reprice › keeps the promo code after a shipping change") == "error")
	local last = bkLines[#bkLines]
	assert(last.kind == "text" and last.text == "🚨 Error: The command exited with status 1" and last.level == "error", "trailing blank lines dropped")
	assert(Log.errors(bkLog.sections[1]) == 3, tostring(Log.errors(bkLog.sections[1])))
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
	assert(#Log.refs({ sections = { { title = "", lines = { Log.line("at x (lib/src/cart/reprice.ts:9)"), { kind = "gap", count = 3 } } } } }, { "src/cart/reprice.ts" }) == 1)
	assert(#Log.refs({ sections = { { title = "", lines = { Log.line("at x (mysrc/cart/reprice.ts:9)") } } } }, { "src/cart/reprice.ts" }) == 0, "a path ends at a folder boundary")

	-- Re-run: each provider gets the failing checks it owns, and the rest are named as unreadable.
	local groups, unowned = Log.byProvider(providers, { ACTIONS_CHECK, BUILD_CHECK, OTHER_CHECK, JOB_CHECK })
	assert(#groups == 2 and groups[1].provider == buildkite and groups[2].provider == actions)
	assert(#groups[1].checks == 2 and groups[1].checks[1] == BUILD_CHECK and groups[1].checks[2] == JOB_CHECK)
	assert(#groups[2].checks == 1 and #unowned == 1 and unowned[1] == OTHER_CHECK)

	-- Actions: one `gh run rerun --failed` per workflow run, however many of its jobs failed.
	local rerunRun, rerunCalls = fakeRun({ ["gh run rerun 902 --failed --repo acme/web"] = "", ["gh run rerun 903 --failed --repo acme/web"] = "" })
	local count = retry(Actions.provider(rerunRun), {
		ACTIONS_CHECK, { name = "lint", url = "https://github.com/acme/web/actions/runs/902/job/2", runId = 902 },
		{ name = "e2e", url = "https://github.com/acme/web/actions/runs/903/job/9", runId = 903 },
	})
	assert(count == 2 and #rerunCalls == 2, tostring(#rerunCalls))
	assert(rerunCalls[1].argv == "gh run rerun 902 --failed --repo acme/web" and rerunCalls[2].argv == "gh run rerun 903 --failed --repo acme/web")
	local _, rerunErr = retry(Actions.provider(fakeRun({}, { status = 1, stdout = "", stderr = "run 902 cannot be rerun\nmore", timed_out = false })), { ACTIONS_CHECK })
	assert(rerunErr == "run 902 cannot be rerun", rerunErr)

	-- Buildkite: a build's link lists its failed jobs and retries each; a job's link retries that job; each build and
	-- job once, asked of the org the link names.
	local retryOutputs = table.clone(Recorded.outputs)
	retryOutputs["bk job retry 0190046e-e199-453b-a302-a21a4d649d31"] = ""
	retryOutputs["bk job retry 0190aaaa-0000-4000-8000-000000000001"] = ""
	local bkRetryRun, bkRetryCalls = fakeRun(retryOutputs)
	local bkCount = retry(Buildkite.provider(bkRetryRun, decode), { BUILD_CHECK, JOB_CHECK, BUILD_CHECK })
	assert(bkCount == 1 and #bkRetryCalls == 2, tostring(#bkRetryCalls))
	assert(bkRetryCalls[1].argv == "bk build view acme/web/429 --recursive --json")
	assert(bkRetryCalls[2].argv == "bk job retry 0190046e-e199-453b-a302-a21a4d649d31")
	assert((bkRetryCalls[2].env :: { [string]: string }).BUILDKITE_ORGANIZATION_SLUG == "acme")
	local jobsRun, jobsCalls = fakeRun(retryOutputs)
	local jobsCount = retry(Buildkite.provider(jobsRun, decode), {
		JOB_CHECK, { name = "Lint", url = "https://buildkite.com/acme/web/builds/430#0190aaaa-0000-4000-8000-000000000001", runId = nil },
	})
	assert(jobsCount == 2 and #jobsCalls == 2, "named jobs are retried without listing the build")
	assert(jobsCalls[1].argv == "bk job retry 0190046e-e199-453b-a302-a21a4d649d31" and jobsCalls[2].argv == "bk job retry 0190aaaa-0000-4000-8000-000000000001")
	local _, bkErr = retry(Buildkite.provider(fakeRun({}, { status = 1, stdout = "", stderr = "job is not retryable", timed_out = false }), decode), { JOB_CHECK })
	assert(bkErr == "job is not retryable", bkErr)
end
