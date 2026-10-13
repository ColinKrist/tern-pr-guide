--!strict
-- Re-run failed checks on the real hub block: the card's failing checks go to the CI module that owns each, and a
-- check no module owns is named in the failure toast. The board is the sample's, with live CI and GitHub swapped in.
local Block: any = require("../src/hub/block")
local Host: any = require("../src/host")
local Log = require("../src/ci/log")

type Toast = { kind: string, title: string }

local KEY = "acme/web#111"

local function check(name: string, url: string, runId: number?): any
	return { name = name, url = url, runId = runId, annotations = {} }
end

-- A provider that owns the checks whose link starts with `prefix`, and records what it was asked to retry.
local function provider(prefix: string, asked: { { string } }, err: string?): Log.Provider
	return {
		owns = function(c: Log.Check): boolean return string.sub(c.url, 1, #prefix) == prefix end,
		read = function() end,
		retry = function(checks: { Log.Check }, _repo: string, done: (number?, string?) -> ())
			local names: { string } = {}
			for _, c in checks do table.insert(names, c.name) end
			table.insert(asked, names)
			if err then return done(nil, err) end
			done(#checks, nil)
		end,
	}
end

return function()
	local stub: { [string]: any } = {
		timer = function(): any return { cancel = function() end } end,
		json = { decode = function(): any return nil end, encode = function(): string return "" end },
		getenv = function(): string? return nil end,
		kv = { get = function(): any return nil end, set = function() end },
	}
	local hostFields: { [string]: any } = {}
	for name, value in stub do
		hostFields[name] = Host[name]
		Host[name] = value
	end

	local ok, err = pcall(function()
		local toasts: { Toast } = {}
		local cx: any = { cwd = "/reader" }
		function cx:render() end
		function cx:frame() end
		function cx:toast(kind: string, title: string)
			table.insert(toasts, { kind = kind, title = title })
		end
		local function press(failing: { any }, providers: { Log.Provider })
			local b: any = Block.init(cx, { "fixture=cases" }, nil)
			b.fixture = nil
			b.ci = providers
			b.github = {
				details = function(_pr: any, done: (any, any) -> ())
					done({ key = KEY, headOid = "h", checks = failing, changedPaths = {}, reviews = {}, threads = {} }, nil)
				end,
			}
			table.clear(toasts)
			Block.event(b, { ev = "action", act = "card-rerun", value = KEY } :: any, cx)
			return b
		end

		local BK = check("buildkite/web", "https://buildkite.com/acme/web/builds/429")
		local GHA = check("build", "https://github.com/acme/web/actions/runs/902/job/1", 902)
		local OTHER = check("deploy/preview", "https://vercel.com/acme/web/abc")

		-- Buildkite alone: its module re-runs it, where GitHub Actions' run ids used to be the only way.
		local bkAsked, ghAsked = {}, {}
		local b = press({ BK }, { provider("https://buildkite.com/", bkAsked), provider("https://github.com/", ghAsked) })
		assert(#bkAsked == 1 and bkAsked[1][1] == "buildkite/web" and #ghAsked == 0)
		assert(#toasts == 1 and toasts[1].kind == "success" and toasts[1].title == "Re-running failed checks on #111", toasts[1].title)
		assert(b.s.busy[KEY] == nil)

		-- A mixed set: each module gets its own checks at once; the one nobody reads is named.
		bkAsked, ghAsked = {}, {}
		press({ GHA, BK, OTHER }, { provider("https://buildkite.com/", bkAsked), provider("https://github.com/", ghAsked) })
		assert(#bkAsked == 1 and #ghAsked == 1 and ghAsked[1][1] == "build")
		assert(#toasts == 2 and toasts[1].kind == "error" and toasts[1].title == "Couldn't re-run deploy/preview: no CI module reads it", toasts[1].title)
		assert(toasts[2].kind == "success")

		-- Nothing any module reads: one failure toast, and nothing re-runs.
		press({ OTHER, check("lint/x", "https://example.com/x") }, { provider("https://buildkite.com/", bkAsked) })
		assert(#toasts == 1 and toasts[1].title == "Couldn't re-run deploy/preview and 1 more: no CI module reads them", toasts[1].title)

		-- A module's failure is the press's failure.
		b = press({ BK }, { provider("https://buildkite.com/", {}, "job is not retryable") })
		assert(#toasts == 1 and toasts[1].kind == "error" and toasts[1].title == "Couldn't re-run checks on #111: job is not retryable", toasts[1].title)
		assert(b.s.busy[KEY] == nil)
	end)
	for name in stub do Host[name] = hostFields[name] end
	if not ok then error(err, 0) end
end
