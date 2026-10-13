--!strict
-- Buildkite for the fixes page and Re-run failed checks: which failing checks are Buildkite builds, the `bk` commands
-- that find a build's failed jobs (`bk build view --recursive --json`), read each one (`bk job log --agent`, which
-- already keeps the lines around the errors) and retry it (`bk job retry`), and the readers of their output. It
-- reaches Buildkite only through the runner it is given, and `bk` signs in with its own saved credentials.
local Log = require("./log")

export type Decode = (text: string) -> any
-- A build page, and the job when the link names one: "https://buildkite.com/acme/web/builds/429#0190…"
export type Build = { org: string, pipeline: string, number: string, job: string? }
export type Failure = { id: string, name: string, org: string }

local M = {}

local BK_MS = 60_000
local MAX_JOBS = 3 -- failed jobs read per build
local MAX_TOKENS = "1500" -- per job log, as `bk` estimates them

function M.build(url: string): Build?
	local org, pipeline, number, rest = string.match(url, "^https://buildkite%.com/([^/#?]+)/([^/#?]+)/builds/(%d+)(.*)$")
	if org == nil then return nil end
	local job = string.match(rest :: string, "^#([%x%-]+)$")
	return { org = org :: string, pipeline = pipeline :: string, number = number :: string, job = job }
end

-- `bk` reads the org from this variable before its saved choice, and picks that org's saved token with it.
local function env(org: string): { [string]: string }
	return { BUILDKITE_ORGANIZATION_SLUG = org }
end

function M.failuresCommand(build: Build): { string }
	return { "bk", "build", "view", build.org .. "/" .. build.pipeline .. "/" .. build.number, "--recursive", "--json" }
end

function M.logCommand(job: string): { string }
	return { "bk", "job", "log", job, "--agent", "--max-tokens", MAX_TOKENS }
end

function M.retryCommand(job: string): { string }
	return { "bk", "job", "retry", job }
end

-- `bk build view --recursive --json`: the failed command jobs across the build and the builds it triggered.
function M.parseFailures(doc: any): { Failure }?
	if type(doc) ~= "table" or type(doc.failures) ~= "table" then return nil end
	local out: { Failure } = {}
	for _, row in doc.failures do
		if type(row) == "table" and type(row.id) == "string" then
			local org = if type(row.build) == "string" then string.match(row.build, "^([^/]+)/") else nil
			table.insert(out, { id = row.id, name = if type(row.name) == "string" and row.name ~= "" then row.name else "Failed job", org = org or "" })
		end
	end
	return out
end

-- `bk job log --agent`: plain text, Buildkite's group markers ("+++ Run tests") read as headings, and the runs it
-- left out ("[… 212 lines omitted …]") as gaps.
function M.parseLog(stdout: string): { Log.Line }
	local raw: { string } = {}
	for line in string.gmatch(stdout, "([^\n]*)\n?") do table.insert(raw, line) end
	while #raw > 0 and string.match(raw[#raw], "^%s*$") do table.remove(raw) end
	local out: { Log.Line } = {}
	for _, line in raw do
		local omitted = string.match(line, "^%[… (%d+) lines? omitted …%]$")
		local gap: Log.Line? = if omitted then { kind = "gap", count = tonumber(omitted) :: number } else nil
		table.insert(out, gap or Log.line(line))
	end
	return out
end

local function failed(out: Log.Out): string?
	if out.timed_out then return "bk timed out" end
	if out.status == 0 then return nil end
	local first = string.match(out.stderr, "[^\n]+") or ("bk exited " .. out.status)
	if out.status == 127 or out.status == -1 then return "bk isn't installed or isn't on the PATH (" .. first .. ")" end
	return first
end

function M.provider(run: Log.Run, decode: Decode): Log.Provider
	local function readJobs(jobs: { Failure }, done: (Log.Log?, string?) -> ())
		local sections: { Log.Section } = {}
		local index = 0
		local function nextJob()
			index += 1
			local job = jobs[index]
			if job == nil or index > MAX_JOBS then return done({ sections = sections }, nil) end
			run(M.logCommand(job.id), { timeout_ms = BK_MS, env = env(job.org) }, function(out)
				local why = failed(out)
				if why then return done(nil, why) end
				table.insert(sections, { title = job.name, lines = M.parseLog(out.stdout) })
				nextJob()
			end)
		end
		nextJob()
	end

	-- The build's failed jobs: the one its link names, else every failed job `bk` lists.
	local function failures(check: Log.Check, done: ({ Failure }?, string?) -> ())
		local build = M.build(check.url) :: Build
		if build.job then return done({ { id = build.job, name = check.name, org = build.org } }, nil) end
		run(M.failuresCommand(build), { timeout_ms = BK_MS, env = env(build.org) }, function(out)
			local why = failed(out)
			if why then return done(nil, why) end
			local ok, doc = pcall(decode, out.stdout)
			local jobs = if ok then M.parseFailures(doc) else nil
			if jobs == nil then return done(nil, "bk returned output this version can't read") end
			if #jobs == 0 then return done(nil, "the build has no failed jobs") end
			for _, job in jobs do
				if job.org == "" then job.org = build.org end
			end
			done(jobs, nil)
		end)
	end

	return {
		owns = function(check: Log.Check): boolean
			return M.build(check.url) ~= nil
		end,
		read = function(check: Log.Check, _repo: string, done: (Log.Log?, string?) -> ())
			failures(check, function(jobs, why)
				if jobs == nil then return done(nil, why) end
				readJobs(jobs, done)
			end)
		end,
		-- Each build once: the jobs its links name, or every failed job when a link names the whole build.
		retry = function(checks: { Log.Check }, _repo: string, done: (number?, string?) -> ())
			local order: { string } = {}
			local named: { [string]: { Failure } } = {}
			local whole: { [string]: Log.Check } = {}
			for _, check in checks do
				local build = M.build(check.url) :: Build
				local id = build.org .. "/" .. build.pipeline .. "/" .. build.number
				if named[id] == nil then
					named[id] = {}
					table.insert(order, id)
				end
				if build.job then
					table.insert(named[id], { id = build.job, name = check.name, org = build.org })
				else
					whole[id] = check
				end
			end
			local jobs: { Failure } = {}
			local taken: { [string]: boolean } = {}
			local function add(list: { Failure })
				for _, job in list do
					if not taken[job.id] then
						taken[job.id] = true
						table.insert(jobs, job)
					end
				end
			end
			Log.each(order, function(id, after)
				local check = whole[id]
				if check == nil then
					add(named[id])
					return after(nil)
				end
				failures(check, function(found, why)
					if found then add(found) end
					after(why)
				end)
			end, function(_, why)
				if why then return done(nil, why) end
				Log.each(jobs, function(job, after)
					run(M.retryCommand(job.id), { timeout_ms = BK_MS, env = env(job.org) }, function(out) after(failed(out)) end)
				end, done)
			end)
		end,
	}
end

return M
