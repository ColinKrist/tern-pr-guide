--!strict
-- Buildkite logs for the fixes page: which failing checks are Buildkite builds, the `bk` commands that find a build's
-- failed jobs (`bk build view --recursive --json`) and read each one (`bk job log --agent`, which already keeps the
-- lines around the errors), and the readers of their output. It reaches Buildkite only through the runner it is
-- given, and `bk` signs in with its own saved credentials.
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

-- `bk job log --agent`: plain text, Buildkite's group markers ("+++ Run tests") kept as plain headings.
function M.parseLog(stdout: string): { string }
	local out: { string } = {}
	for line in string.gmatch(stdout, "([^\n]*)\n?") do
		table.insert(out, (string.gsub(line, "^[~+%-^][~+%-^][~+%-^] ", "")))
	end
	while #out > 0 and string.match(out[#out], "^%s*$") do table.remove(out) end
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

	return {
		owns = function(check: Log.Check): boolean
			return M.build(check.url) ~= nil
		end,
		read = function(check: Log.Check, _repo: string, done: (Log.Log?, string?) -> ())
			local build = M.build(check.url) :: Build
			if build.job then return readJobs({ { id = build.job, name = check.name, org = build.org } }, done) end
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
				readJobs(jobs, done)
			end)
		end,
	}
end

return M
