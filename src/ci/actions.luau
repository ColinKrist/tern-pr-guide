--!strict
-- GitHub Actions for the fixes page and Re-run failed checks: which failing checks are Actions jobs, the
-- `gh run view --log-failed` command that reads one, the cut that keeps the lines around its errors, and
-- `gh run rerun --failed` for each failed run. It reaches GitHub only through the runner it is given.
local Log = require("./log")

local M = {}

local LOG_MS = 60_000
local BEFORE, AFTER = 12, 3 -- lines kept around each error
local TAIL = 30 -- lines kept from the end when no line reads as an error
local MAX_LINES = 120 -- per job

-- "https://github.com/acme/web/actions/runs/902/job/7" → 7
function M.jobId(url: string): string?
	return string.match(url, "/actions/runs/%d+/job/(%d+)")
end

function M.command(repo: string, check: Log.Check): { string }
	local argv = { "gh", "run", "view", tostring(check.runId), "--repo", repo, "--log-failed" }
	local job = M.jobId(check.url)
	if job then
		table.insert(argv, "--job")
		table.insert(argv, job)
	end
	return argv
end

-- Runs the failed jobs of one workflow run again; zero tokens, and never sent but by a press.
function M.retryCommand(repo: string, runId: number): { string }
	return { "gh", "run", "rerun", tostring(runId), "--failed", "--repo", repo }
end

local function reason(out: Log.Out): string?
	if out.timed_out then return "gh timed out" end
	if out.status == 0 then return nil end
	return string.match(out.stderr, "[^\n]+") or ("gh exited " .. out.status)
end

local function isError(text: string, flagged: boolean): boolean
	if flagged then return true end
	return string.find(text, "%f[%a][Ee]rror[%s:%[]") ~= nil or string.find(text, "FAIL", 1, true) ~= nil
		or string.find(text, "Traceback", 1, true) ~= nil or string.find(text, "panic:", 1, true) ~= nil
		or string.find(text, "✕", 1, true) ~= nil or string.find(text, "✗", 1, true) ~= nil
end

-- The lines worth reading: a window around each error, gaps marked, or the tail when nothing reads as one.
local function cut(lines: { string }, errors: { boolean }): { string }
	local keep: { boolean } = {}
	local any = false
	for i in lines do
		if errors[i] then
			any = true
			for k = math.max(1, i - BEFORE), math.min(#lines, i + AFTER) do keep[k] = true end
		end
	end
	if not any then
		for k = math.max(1, #lines - TAIL + 1), #lines do keep[k] = true end
	end
	local out: { string } = {}
	local skipped = 0
	for i, text in lines do
		if keep[i] then
			if skipped > 0 then table.insert(out, "… " .. skipped .. (if skipped == 1 then " line omitted" else " lines omitted")) end
			skipped = 0
			if #out < MAX_LINES then table.insert(out, text) end
		else
			skipped += 1
		end
	end
	return out
end

-- `gh run view --log-failed` prints "job<TAB>step<TAB>timestamp text" per line; a section per job.
function M.parse(stdout: string): Log.Log
	local order: { string } = {}
	local byJob: { [string]: { lines: { string }, errors: { boolean } } } = {}
	for raw in string.gmatch(stdout, "([^\n]*)\n?") do
		local job, rest = string.match(raw, "^([^\t]*)\t[^\t]*\t(.*)$")
		if job == nil then job, rest = "", raw end
		local text = rest :: string
		text = string.gsub(text, "^\239\187\191", "")
		text = string.gsub(text, "^%d%d%d%d%-%d%d%-%d%dT[%d:%.]+Z ?", "")
		text = string.gsub(text, "\27%[[%d;]*[A-Za-z]", "")
		text = string.gsub(text, "\r$", "")
		local flagged = false
		if string.sub(text, 1, 8) == "##[error" then
			text, flagged = string.gsub(text, "^##%[error%]", ""), true
		end
		text = string.gsub(text, "^##%[%a+%]", "")
		if raw ~= "" and not string.find(rest :: string, "##[endgroup]", 1, true) then
			local name = job :: string
			if byJob[name] == nil then
				byJob[name] = { lines = {}, errors = {} }
				table.insert(order, name)
			end
			local entry = byJob[name]
			table.insert(entry.lines, text)
			entry.errors[#entry.lines] = isError(text, flagged)
		end
	end
	local sections: { Log.Section } = {}
	for _, name in order do
		local entry = byJob[name]
		table.insert(sections, { title = name, lines = cut(entry.lines, entry.errors) })
	end
	return { sections = sections }
end

function M.provider(run: Log.Run): Log.Provider
	return {
		owns = function(check: Log.Check): boolean
			return check.runId ~= nil and string.find(check.url, "/actions/runs/", 1, true) ~= nil
		end,
		read = function(check: Log.Check, repo: string, done: (Log.Log?, string?) -> ())
			run(M.command(repo, check), { timeout_ms = LOG_MS }, function(out)
				local why = reason(out)
				if why then return done(nil, why) end
				local log = M.parse(out.stdout)
				if #log.sections == 0 then return done(nil, "the run has no failed steps") end
				done(log, nil)
			end)
		end,
		retry = function(checks: { Log.Check }, repo: string, done: (number?, string?) -> ())
			local ids: { number } = {}
			for _, check in checks do
				if check.runId and table.find(ids, check.runId) == nil then table.insert(ids, check.runId) end
			end
			Log.each(ids, function(id, after)
				run(M.retryCommand(repo, id), { timeout_ms = LOG_MS }, function(out) after(reason(out)) end)
			end, done)
		end,
	}
end

return M
