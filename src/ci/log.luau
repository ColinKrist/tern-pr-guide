--!strict
-- The shape every CI's failed-check log takes on the fixes page, and the one contract a CI module meets: it reads the
-- logs of its failed checks and retries them. Pure: it knows no CI. `ci/actions.luau` and `ci/buildkite.luau` each
-- claim their own checks; the fixes page and Re-run failed checks ask whichever claims a check.

export type Out = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Run = (argv: { string }, opts: { timeout_ms: number?, env: { [string]: string }? }, done: (out: Out) -> ()) -> ()

-- The part of a failing check a CI needs to find its log: GitHub's details link and, for Actions, the run.
export type Check = { name: string, url: string, runId: number? }

-- One failed job or step, already cut down to the lines around its errors.
export type Section = { title: string, lines: { string } }
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
		for _, text in section.lines do
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
