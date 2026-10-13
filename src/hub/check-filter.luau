--!strict
-- Reads named failures for the check filter, on demand. Ordinary refreshes stay count-only unless
-- an ignore rule is enabled. A response belongs only to the exact PR and checks snapshot requested.
local Runtime = require("./runtime")
local State = require("./state")

local M = {}

function M.read(b: Runtime.Block, cx: BlockCx, repo: string?)
	if b.fixture or b.closed then return end
	local wanted = State.ignoredRepositories(b.s)
	if repo then wanted[string.lower(repo)] = true end
	local selected = {}
	for _, pr in b.s.prs do
		if wanted[string.lower(pr.repo)] and pr.checks.state == "failing" and pr.checks.failedNames == nil then
			table.insert(selected, { pr = pr, checks = pr.checks, head = pr.headOid })
		end
	end
	local offset = 1
	local function page()
		if b.closed or offset > #selected then return end
		local ids: { string } = {}
		local last = math.min(offset + 9, #selected)
		for i = offset, last do table.insert(ids, selected[i].pr.id) end
		b.github.checkNames(ids, function(update, err)
			if b.closed then return end
			if err then
				b.s.error = err
				Runtime.draw(b, cx)
				return
			end
			if update then
				for i = offset, last do
					local requested = selected[i]
					local pr = State.prOf(b.s, requested.pr.key)
					local result = update.byId[requested.pr.id]
					if pr and pr == requested.pr and pr.checks == requested.checks and pr.headOid == requested.head and result and result.headOid == requested.head then
						pr.checks = result.checks
					end
				end
				State.project(b.s)
				Runtime.draw(b, cx)
			end
			offset = last + 1
			page()
		end)
	end
	page()
end

return M
