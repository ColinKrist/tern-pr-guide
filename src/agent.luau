--!strict
-- The reader's own AI agent (OMP) writing a guide in two passes that run side by side: a fast
-- explanation of the PR, and a review that drafts comments. Holds the model and effort of each, the
-- models there are to pick from, and the files a run reads. src/agent-host.luau finds the agent and runs it.
local Lens = require("./lens")
local Pr = require("./pr")

-- One model `omp models` lists: what `--model` takes, its display name, and the thinking levels
-- `--thinking` takes for it (none when it can't think).
export type Model = { selector: string, name: string, efforts: { string } }

-- The two passes of a run: the explanation writes the walkthrough, the review the comments.
export type Pass = "explain" | "review"

-- A model as `--model` takes it, and the effort `--thinking` gets (none for a model that can't think).
export type Choice = { model: string, effort: string? }

-- `omp` as the login shell finds it, that shell's PATH (`omp` runs on an interpreter found there),
-- the review model and effort (agent fixes and the feedback summary run with them too), the
-- explanation's, whether a run reviews at all, the models there are to choose from (empty until
-- listed), the lenses there are to review through and the name of the one a review uses.
export type Agent = {
 command: string, path: string, model: string, effort: string?, explain: Choice, review: boolean,
 models: { Model }, lenses: { Lens.Lens }, lens: string,
}

-- What the reader picked, as kept between starts: `Agent` without what is found or listed.
export type Picks = { model: string, effort: string?, explain: Choice, review: boolean, lens: string }

-- Writing a guide for the page's PR: which passes are going, the seconds since the run started,
-- how long each pass is expected to take, and the first line of why the explanation last failed.
export type Run = { agent: Agent, explaining: boolean, reviewing: boolean, seconds: number, expected: { [Pass]: number }, error: string? }

local MARKS = { ctx = " ", add = "+", del = "-" }

-- Every thinking level `omp --thinking` takes.
local EFFORTS: { [string]: boolean } = { off = true, minimal = true, low = true, medium = true, high = true, xhigh = true, max = true, auto = true }
-- The effort a newly picked model gets when it can't keep the current one.
local DEFAULT_EFFORT = "high"

local M = {}

-- How far along a run `seconds` in probably is, 0 to 1, when one takes about `expected` seconds:
-- `omp -p` reports nothing until it ends, so this eases toward 90% at `expected` and then creeps,
-- never claiming more than 95% before the run is done.
function M.progress(seconds: number, expected: number): number
 return math.min(0.95, 1 - math.exp(-2.3 * seconds / math.max(expected, 1)))
end

-- OMP's settings, under the home directory.
M.CONFIG = "/.omp/agent/config.yml"

-- `raw` as OMP writes a model role ("provider/id:effort"), split into the model and its effort.
function M.parseChoice(raw: string): (string, string?)
 local model, effort = string.match(raw, "^(.*):(%a+)$")
 if model and EFFORTS[effort :: string] then return model, effort end
 return raw, nil
end

-- The picks kept under the "model" key, `saved`, over OMP's own review model `fallback`: the review
-- model, the explanation's (the review model until the reader picks one), the review on unless
-- turned off, and the lens. Nil when there is no model at all.
function M.picks(saved: any, fallback: Choice?): Picks?
 local kept = if type(saved) == "table" then saved else {}
 local review: Choice? = if type(kept.model) == "string"
  then { model = kept.model, effort = if type(kept.effort) == "string" then kept.effort else nil }
  else fallback
 if not review then return nil end
 local explain: Choice = if type(kept.explainModel) == "string"
  then { model = kept.explainModel, effort = if type(kept.explainEffort) == "string" then kept.explainEffort else nil }
  else table.clone(review)
 return {
  model = review.model, effort = review.effort, explain = explain, review = kept.review ~= false,
  lens = if type(kept.lens) == "string" then kept.lens else Lens.DEFAULT,
 }
end

-- What `M.picks` reads back.
function M.saved(agent: Agent): { [string]: any }
 return {
  model = agent.model, effort = agent.effort, explainModel = agent.explain.model, explainEffort = agent.explain.effort,
  review = agent.review, lens = agent.lens,
 }
end

function M.new(command: string, path: string, picks: Picks): Agent
 return {
  command = command, path = path, model = picks.model, effort = picks.effort, explain = picks.explain, review = picks.review,
  models = {}, lenses = {}, lens = picks.lens,
 }
end

-- The model and effort `pass` runs with.
function M.choiceFor(agent: Agent, pass: Pass): Choice
 return if pass == "review" then { model = agent.model, effort = agent.effort } else agent.explain
end

-- A model selector without its provider, as the page names it.
function M.shortName(model: string): string
 return string.match(model, "[^/]+$") or model
end

-- A run with no pass going.
function M.idle(agent: Agent): Run
 return { agent = agent, explaining = false, reviewing = false, seconds = 0, expected = { explain = 0, review = 0 }, error = nil }
end

-- Starts both passes of `run`, or only the explanation when the reader turned the review off.
function M.start(run: Run, expected: { [Pass]: number })
 run.explaining, run.reviewing, run.seconds, run.expected, run.error = true, run.agent.review, 0, expected, nil
end

-- Whether either pass is still going.
function M.busy(run: Run): boolean
 return run.explaining or run.reviewing
end

-- The lens a run reviews through.
function M.currentLens(agent: Agent): Lens.Lens
 return Lens.pick(agent.lenses, agent.lens)
end

-- The chat models in `omp models --json` output, decoded; empty when it isn't that shape.
function M.parseModels(raw: any): { Model }
 local models = {}
 if type(raw) ~= "table" or type(raw.models) ~= "table" then return models end
 for _, item in raw.models do
  if type(item) == "table" and type(item.selector) == "string" and (item.kind == nil or item.kind == "chat") then
   local efforts = {}
   if type(item.thinking) == "table" then
    for _, level in item.thinking do
     if type(level) == "string" then table.insert(efforts, level) end
    end
   end
   table.insert(models, { selector = item.selector, name = if type(item.name) == "string" then item.name else item.selector, efforts = efforts })
  end
 end
 return models
end

-- The models whose name or selector contains `query`, ignoring case, in list order.
function M.matching(models: { Model }, query: string): { Model }
 local needle = string.lower(query)
 if needle == "" then return models end
 local found = {}
 for _, model in models do
  if string.find(string.lower(model.name), needle, 1, true) or string.find(string.lower(model.selector), needle, 1, true) then
   table.insert(found, model)
  end
 end
 return found
end

-- The effort `model` runs with when `wanted` was asked for: `wanted` when it takes it, else high,
-- else its strongest; nil for a model that can't think.
function M.effortFor(model: Model, wanted: string?): string?
 if #model.efforts == 0 then return nil end
 if wanted and table.find(model.efforts, wanted) then return wanted end
 if table.find(model.efforts, DEFAULT_EFFORT) then return DEFAULT_EFFORT end
 return model.efforts[#model.efforts]
end

-- The `omp` command that has `agent` follow the prompt at `promptPath` with `pass`'s model.
function M.argv(agent: Agent, pass: Pass, promptPath: string): { string }
 local choice = M.choiceFor(agent, pass)
 local argv = { agent.command, "-p", "--model", choice.model }
 if choice.effort then
  table.insert(argv, "--thinking")
  table.insert(argv, choice.effort)
 end
 table.insert(argv, M.request(promptPath))
 return argv
end

-- The first `omp` in the directories of `path` (a colon-separated PATH value) that `exists`.
function M.findOnPath(path: string, exists: (string) -> boolean): string?
 for dir in string.gmatch(path, "[^:]+") do
  local candidate = dir .. "/omp"
  if exists(candidate) then return candidate end
 end
 return nil
end

-- A YAML scalar without its quotes or trailing comment.
local function scalar(raw: string): string
 local quoted = string.match(raw, "^\"([^\"]*)\"") or string.match(raw, "^'([^']*)'")
 if quoted then return quoted end
 return (string.gsub(raw, "%s+#.*$", ""))
end

-- The model of OMP's `review` role, else its `default` one, from the `modelRoles:` block of its
-- config.yml; nil when neither is set.
function M.reviewModel(config: string): string?
 local roles: { [string]: string } = {}
 local inRoles = false
 for line in string.gmatch(config .. "\n", "([^\n]*)\n") do
  line = string.gsub(line, "%s+$", "")
  if line == "" or string.match(line, "^%s*#") then continue end
  if string.match(line, "^%S") then
   inRoles = string.match(line, "^modelRoles:%s*$") ~= nil or string.match(line, "^modelRoles:%s+#") ~= nil
  elseif inRoles then
   local key, value = string.match(line, "^  ([%w_%-]+):%s*(.*)$")
   if key and value then roles[key] = scalar(value) end
  end
 end
 for _, role in { "review", "default" } do
  if roles[role] and roles[role] ~= "" then return roles[role] end
 end
 return nil
end

-- Where a run for `pr` keeps the diff and prompt it reads.
function M.workDir(pr: Pr.PR): string
 return "/tmp/prguide-" .. string.gsub(pr.repo, "/", "-") .. "-" .. pr.number
end

-- What the first line of the numbered diff says about the columns after it.
M.DIFF_LEGEND = "Columns: old line number, new line number, then a mark (space = unchanged, + = added, - = removed) and the line. "
 .. "Added lines have only a new number; removed lines have only an old number."

-- Every changed file's diff but generated files', with the line numbers in front of each line, so the
-- agent can point at lines without counting: the old-file number (blank on an added line), the
-- new-file number (blank on a removed line), the mark and the text.
function M.numberedDiff(files: { Pr.File }): string
 local out = { M.DIFF_LEGEND, "" }
 for _, file in files do
  if file.group == "generated" then continue end
  table.insert(out, "=== " .. file.path .. " (" .. file.status .. ")")
  if file.binary then table.insert(out, "(binary, no lines)") end
  for _, row in file.rows do
   if row.kind == "hunk" then
    table.insert(out, "")
    table.insert(out, "@@ -" .. row.oldStart .. " +" .. row.newStart .. " @@" .. (if row.label then " " .. row.label else ""))
   else
    table.insert(out, string.format("%5s %5s %s %s", if row.old then tostring(row.old) else "", if row.new then tostring(row.new) else "", MARKS[row.kind], row.text))
   end
  end
  table.insert(out, "")
 end
 return table.concat(out, "\n")
end

-- The prompt template with its `{{placeholders}}` filled in.
function M.prompt(template: string, values: { [string]: string }): string
 return (string.gsub(template, "{{(%w+)}}", function(name: string): string
  return values[name] or "{{" .. name .. "}}"
 end))
end

-- The prompt section that has the review go through `lens`: nothing for a lens without
-- instructions, so a plain review reads as it always did.
function M.focus(lens: Lens.Lens): string
 if lens.instructions == "" then return "" end
 return "## Review lens: " .. lens.name .. "\n\n"
  .. "The reader chose this lens. It changes what you look for and how you word comments, never the "
  .. "format you write below, which stays exactly the same.\n\n"
  .. lens.instructions .. "\n\n"
end

-- The one message `omp -p` gets.
function M.request(promptPath: string): string
 return "Read " .. promptPath .. " and follow it exactly."
end

return M
