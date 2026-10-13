--!strict
-- The shape every CI's failed-check log takes on the fixes page, and the one contract a CI module meets: it reads the
-- logs of its failed checks and retries them. Pure: it knows no CI. `ci/actions.luau` and `ci/buildkite.luau` each
-- claim their own checks; the fixes page and Re-run failed checks ask whichever claims a check.

export type Out = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Run = (argv: { string }, opts: { timeout_ms: number?, env: { [string]: string }? }, done: (out: Out) -> ()) -> ()

-- The part of a failing check a CI needs to find its log: GitHub's details link and, for Actions, the run.
export type Check = { name: string, url: string, runId: number? }

-- What a log line is, for how the page draws it: an error, a step's heading, a command the job ran, or the rest.
export type Level = "error" | "heading" | "command" | "plain"
-- A line of the log, or a run of lines the CI or the cut left out.
export type Line = { kind: "text", text: string, level: Level } | { kind: "gap", count: number }
-- One failed job or step, already cut down to the lines around its errors.
export type Section = { title: string, lines: { Line } }
export type Log = { sections: { Section } }
-- A place in the pull request's files that the log names, with the log line that names it.
export type Ref = { path: string, line: number, text: string }

-- What the page holds for one check's log while and after it is read.
export type Load = { state: "loading" } | { state: "loaded", log: Log } | { state: "failed", reason: string }

-- A CI module: `owns` says, without running anything, whether a check is its own; `read` reads that check's log.
-- `retry` re-runs failed checks; it gets every failing check it owns at once, so it can run each run or build once,
-- and answers how many it started.
export type Provider = {
	owns: (check: Check) -> boolean,
	read: (check: Check, repo: string, done: (log: Log?, err: string?) -> ()) -> (),
	retry: (checks: { Check }, repo: string, done: (count: number?, err: string?) -> ()) -> (),
}
-- A provider and the checks it owns, in the order of the providers.
export type Group = { provider: Provider, checks: { Check } }

local M = {}

local MAX_REFS = 5

-- How a raw log line reads, first match wins. `strip` is the CI's marker the page drops and keeps the rest of.
type Rule = { level: Level, pattern: string, strip: boolean? }
local RULES: { Rule } = {
	{ level = "error", pattern = "^##%[error%]", strip = true }, -- Actions' own error flag
	{ level = "heading", pattern = "^##%[group%]", strip = true }, -- an Actions step
	{ level = "error", pattern = "^%-%-%- FAIL" }, -- go test, not a Buildkite group
	{ level = "heading", pattern = "^[~+%-^][~+%-^][~+%-^] ", strip = true }, -- a Buildkite group: ---, +++, ~~~
	{ level = "command", pattern = "^##%[command%]", strip = true },
	{ level = "error", pattern = "%f[%a][Ee]rror[%s:%[]" },
	{ level = "error", pattern = "error TS%d" },
	{ level = "error", pattern = "FAIL" },
	{ level = "error", pattern = "Traceback" },
	{ level = "error", pattern = "panic:" },
	{ level = "error", pattern = "^%s*●" }, -- jest
	{ level = "error", pattern = "^E   " }, -- pytest
	{ level = "error", pattern = "✕" },
	{ level = "error", pattern = "✗" },
	{ level = "error", pattern = "🚨" },
	{ level = "command", pattern = "^%$ " },
}

local function ruleFor(text: string): Rule?
	for _, rule in RULES do
		if string.find(text, rule.pattern) then return rule end
	end
	return nil
end

function M.classify(text: string): Level
	local rule = ruleFor(text)
	return if rule then rule.level else "plain"
end

-- A raw log line as the page shows it: classified, with a CI's marker dropped ("##[group]Run tests" → "Run tests").
-- Any other Actions marker ("##[warning]") is dropped too.
function M.line(raw: string): Line
	local rule = ruleFor(raw)
	local text = if rule and rule.strip then string.gsub(raw, rule.pattern, "") else raw
	text = string.gsub(text, "^##%[%a+%]", "")
	return { kind = "text", text = text, level = if rule then rule.level else "plain" }
end

-- How many lines of `section` read as errors.
function M.errors(section: Section): number
	local count = 0
	for _, line in section.lines do
		if line.kind == "text" and line.level == "error" then count += 1 end
	end
	return count
end

-- The provider that owns `check`, the first in order.
function M.providerFor(providers: { Provider }, check: Check): Provider?
	for _, provider in providers do
		if provider.owns(check) then return provider end
	end
	return nil
end

-- `checks` split by the provider that owns each, and the checks no provider owns.
function M.byProvider(providers: { Provider }, checks: { Check }): ({ Group }, { Check })
	local groups: { Group } = {}
	local unowned: { Check } = {}
	for _, provider in providers do
		local mine: { Check } = {}
		for _, check in checks do
			if M.providerFor(providers, check) == provider then table.insert(mine, check) end
		end
		if #mine > 0 then table.insert(groups, { provider = provider, checks = mine }) end
	end
	for _, check in checks do
		if M.providerFor(providers, check) == nil then table.insert(unowned, check) end
	end
	return groups, unowned
end

-- Runs `step` on each item in turn, stopping at the first error; answers how many ran.
function M.each<T>(items: { T }, step: (item: T, done: (err: string?) -> ()) -> (), done: (count: number?, err: string?) -> ())
	local function go(i: number)
		if i > #items then return done(#items, nil) end
		step(items[i], function(err)
			if err then return done(nil, err) end
			go(i + 1)
		end)
	end
	go(1)
end

-- `path:line` mentions in the log that point into the pull request's changed files, each once, in log order. A log
-- path may carry the build machine's folder ("/workdir/src/a.ts"), so a changed path matches when the log path ends
-- with it.
function M.refs(log: Log, changedPaths: { string }): { Ref }
	local out: { Ref } = {}
	local seen: { [string]: boolean } = {}
	for _, section in log.sections do
		for _, entry in section.lines do
			local text = if entry.kind == "text" then entry.text else ""
			for raw, line in string.gmatch(text, "([%w%._%-/]+%.%w+):(%d+)") do
				for _, path in changedPaths do
					local tail = string.sub(raw, -#path)
					if tail == path and (#raw == #path or string.sub(raw, -#path - 1, -#path - 1) == "/") then
						local key = path .. ":" .. line
						if not seen[key] and #out < MAX_REFS then
							seen[key] = true
							table.insert(out, { path = path, line = tonumber(line) :: number, text = text })
						end
					end
				end
			end
		end
	end
	return out
end

return M
