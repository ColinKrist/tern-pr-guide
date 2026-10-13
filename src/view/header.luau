--!strict
-- The pinned header: PR title and review button, progress and actions, and whichever panel is open.
local Agent = require("../agent")
local Checks = require("../hub/checks")
local ChecksView = require("./hub/checks")
local Guide = require("../guide")
local Help = require("./help")
local Model = require("../hub/model")
local Progress = require("./progress")
local Review = require("../review")
local ReviewPanel = require("./review-panel")
local SearchPanel = require("./search-panel")
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local METER_CELLS = 24

local M = {}

local function reviewButton(s: State.State): Node
 local posted = s.review.posted
 local label = if not posted then "Submit review" elseif posted.delivery.kind == "saved" then "Dry run saved" else "Review posted"
 local kids = { span("gp-rv-button-label", label) }
 if posted then table.insert(kids, el("span", { class = "gp-rv-button-count" }, { Ui.icon("check") })) end
 table.insert(kids, Ui.keys("r"))
 return el("span", { class = "gp-rv-button" .. (if s.reviewOpen then " gp-rv-button-open" else ""), actions = { click = "toggle-review" } }, kids)
end

-- A quiet action in the status row: its icon and key, with its name for screen readers (Tern has no tooltip).
local function headerAction(name: string, icon: string, keyHint: string, action: string, class: string?): Node
 return el("span", { class = "gp-hdr-act gp-hdr-act-ico" .. (if class then " " .. class else ""), key = action, aria = name, actions = { click = action } }, {
  Ui.icon(icon), Ui.keys(keyHint),
 })
end

-- Settings: the models, their effort and the lens, in the menu Page.layer opens under it. Not while a
-- run is going, which reads them when it finishes.
local function settingsAction(run: Agent.Run?, open: boolean): Node?
 if not run or Agent.busy(run) then return nil end
 return headerAction("Settings", "settings", "⇧M", "toggle-models", if open then "gp-hdr-act-open" else nil)
end

-- Pull request: the host's menu of merge, close and the rest, which it hangs under this button. Only on a page the PR
-- hub shows for a pull request on its board. Its ⇧P is in the `?` panel.
local function prAction(hosted: State.Hosted?): Node?
 if not hosted or not hosted.pr then return nil end
 return el("span", { class = "gp-hdr-act" .. (if hosted.prOpen then " gp-hdr-act-open" else ""), key = "pr", aria = "Pull request", actions = { click = "hub-pr-menu" } }, {
  span("gp-hdr-act-label", "Pull request"), Ui.icon("chev"),
 })
end

local function reviewsMark(mark: Checks.ReviewMark, open: string): Node
 local kids: { Node }
 if mark.kind == "approved" then
  kids = { el("span", { class = "gp-hc-ci gp-hc-ci-ok", key = "ok" }, { Ui.icon("check"), span("gp-hc-ci-n", "Approved · " .. mark.approvals) }) }
 elseif mark.kind == "changes" then
  kids = { el("span", { class = "gp-hc-ci gp-hc-ci-bad", key = "bad" }, { Ui.icon("x"), span("gp-hc-ci-n", "Changes requested") }) }
 else
  kids = { el("span", { class = "gp-hc-ci gp-hdr-mark-wait", key = "wait" }, { span("gp-hcl-wait", ""), span("gp-hc-ci-n", "Review required") }) }
 end
 return el("span", { class = "gp-hc-chk gp-hdr-mark" .. open, key = "reviews", aria = "Reviewers and checks", actions = { click = "hub-checks" } }, kids)
end

-- The PR's reviews and checks marks, each opening the host's popover of reviewers and checks under them, as `v` does.
local function statusMarks(status: State.Status): Node
 local open = if status.open then " gp-hc-chk-open" else ""
 local kids = { reviewsMark(status.reviews, open) }
 if status.checks then
  table.insert(kids, span("gp-status-sep", "·"))
  table.insert(kids, el("span", { class = "gp-hc-chk gp-hdr-mark" .. open, key = "checks", aria = "Reviewers and checks", actions = { click = "hub-checks" } }, ChecksView.summary(status.checks, true)))
 end
 table.insert(kids, span("gp-status-sep", "·"))
 return el("span", { class = "gp-status-marks", key = "marks" }, kids)
end

-- The views of a PR as Tern's tabs, with the key that cycles them: Guided and Files with a guide, only Files
-- without, and Fixes first when the host (the PR hub) has them. The block reads a click as the same `view=<id>`
-- action the key sends (see Page.viewTabsPath); the host reads a click on Fixes.
local function viewSwitch(s: State.State): Node
 local items: { Ui.ViewTab } = {}
 if s.hosted and s.hosted.fixes then table.insert(items, { id = "fixes", label = "Fixes" }) end
 if State.switchable(s) then table.insert(items, { id = "guided", label = "Guided" }) end
 table.insert(items, { id = "files", label = "Files" })
 return Ui.viewTabs(items, if State.switchable(s) then s.view else "files")
end

-- What each pass's row says it is doing.
local EXPLAINING, REVIEWING = "Explaining the changes…", "Reviewing for issues…"

-- The explanation going, with nothing to read yet: a turning spark, the phrase written in once,
-- an estimated progress bar, and the clock.
local function explainingRow(run: Agent.Run): Node
 return Progress.row("div", "gp-ai gp-ai-busy", "ai", EXPLAINING, run.seconds.explain, run.expected.explain)
end

-- The review going under a page the reader can already read: one still, muted run of a spark, the
-- phrase, a bar and the clock.
local function reviewing(run: Agent.Run): Node
 return el("span", { class = "gp-ai-quiet", key = "reviewing" }, {
  el("span", { class = "gp-ai-quiet-icon", key = "spark" }, { Ui.icon("sparkle") }),
  span("gp-ai-quiet-text", REVIEWING),
  Progress.bar(run.seconds.review, run.expected.review, false),
  el("span", { class = "gp-ai-meta", key = "meta", text = Agent.clock(run.seconds.review) }),
 })
end

local function aiButton(label: string, keyHint: string, action: string, primary: boolean): Node
 return el("span", { class = "gp-btn gp-btn-keyed gp-ai-button" .. (if primary then " gp-btn-primary" else ""), key = action, actions = { click = action } }, {
  span("gp-ai-button-label", label),
  Ui.keys(keyHint),
 })
end

-- The reader's AI agent: Generate AI guide while the page has none, and Generate LLM review, and
-- why the last explanation failed. The models they use are in Settings. While the explanation runs
-- with nothing new to read, the row is its progress; while the review runs, the review's quiet
-- progress takes its button's place.
local function aiRow(run: Agent.Run, hasGuide: boolean): Node
 if run.explaining then return explainingRow(run) end
 local kids = {}
 if not hasGuide then table.insert(kids, aiButton("Generate AI guide", "⇧G", "generate-guide", true)) end
 if run.reviewing then
  table.insert(kids, reviewing(run))
 else
  table.insert(kids, aiButton("Generate LLM review", "⇧R", "draft-review", false))
 end
 if run.error then table.insert(kids, span("gp-ai-error", "Couldn't explain the changes: " .. run.error)) end
 return el("div", { class = "gp-ai", key = "ai" }, kids)
end

local function status(s: State.State, counts: Review.Counts): Node
 local r = s.review
 local total = #r.pr.files
 local cells, filled = {}, math.floor(METER_CELLS * counts.filesReviewed / math.max(total, 1) + 0.5)
 for i = 1, METER_CELLS do table.insert(cells, span(if i <= filled then "gp-cell gp-cell-on" else "gp-cell", "")) end
 local kids = {}
 -- Each optional item travels with its separator, so the guided page's one-line header cuts both
 -- together when the row runs out of room.
 local function item(node: Node)
  table.insert(kids, el("span", { class = "gp-status-item" }, { span("gp-status-sep", "·"), node }))
 end
 -- Who opened the PR and when, as GitHub's PR header says it.
 local pr = r.pr
 if pr.author ~= "" or pr.createdAt ~= "" then
  local opened = if pr.author ~= "" then pr.author .. " opened" else "Opened"
  if pr.createdAt ~= "" then opened ..= " " .. Model.ago(pr.createdAt, s.now) end
  table.insert(kids, el("span", { class = "gp-status-item" }, { span("gp-status-text", opened), span("gp-status-sep", "·") }))
 end
 local hosted = s.hosted
 if hosted and hosted.status then table.insert(kids, statusMarks(hosted.status)) end
 table.insert(kids, el("div", { class = "gp-meter" }, cells))
 table.insert(kids, span("gp-status-text", counts.filesReviewed .. " of " .. total .. " files reviewed"))
 if r.guide.lens then item(span("gp-status-text gp-status-lens", r.guide.lens .. " lens")) end
 if counts.waiting > 0 then
  item(el("span", {
   class = "gp-status-link",
   text = counts.waiting .. " " .. r.guide.author .. " " .. (if counts.waiting == 1 then "suggestion" else "suggestions") .. " waiting for you",
   actions = { click = "toggle-review" },
  }))
 end
 if Guide.isStale(r.guide, r.pr) then item(span("gp-status-text", "Review written for an older version of this PR")) end
 table.insert(kids, Ui.spacer())
 table.insert(kids, headerAction("Search", "search", "/", "open-search"))
 table.insert(kids, headerAction("Open on GitHub", "open", "g", "open-github"))
 local all = counts.filesReviewed == total
 table.insert(kids, headerAction(if all then "Unmark all reviewed" else "Mark all reviewed", "check", "m", "mark-all", if all then "gp-hdr-act-done" else nil))
 local settings = settingsAction(s.ai, s.models ~= nil)
 if settings then table.insert(kids, settings) end
 local prButton = prAction(hosted)
 if prButton then table.insert(kids, prButton) end
 return el("div", { class = "gp-status", key = "status" }, kids)
end

function M.view(s: State.State, motion: Ui.Motion): Node
 local pr = s.review.pr
 local counts = Review.counts(s.review)
 local title = { span("gp-title-num", "#" .. pr.number), span("gp-title-text", pr.title), Ui.spacer() }
 -- In the hub, the way back to the board leads the title, as on the fixes page.
 if s.hosted then
  table.insert(title, 1, el("span", { class = "gp-hdr-act gp-back", key = "back", actions = { click = "pages-back" } }, {
   el("span", { class = "gp-back-ico" }, { Ui.icon("chev-r") }), span("gp-hdr-act-label", "Pull requests"), Ui.keys("esc"),
  }))
 end
 if State.switchable(s) or (s.hosted and s.hosted.fixes) then table.insert(title, viewSwitch(s)) end
 table.insert(title, reviewButton(s))
 local parts = {
  el("div", { class = "gp-title", key = "title" }, title),
  status(s, counts),
 }
 if s.ai then table.insert(parts, aiRow(s.ai, s.review.guide.guided or State.switchable(s))) end
 if s.search then table.insert(parts, SearchPanel.view(s.search, s.review.guide.guided, Ui.entering(motion, "p:search", "gp-enter-panel"))) end
 if s.helpOpen then table.insert(parts, Help.view(s.closing.help == true, { guided = s.review.guide.guided, switch = State.switchable(s), hosted = s.hosted }, Ui.entering(motion, "p:help", "gp-enter-panel"))) end
 if s.reviewOpen then table.insert(parts, ReviewPanel.view(s, motion)) end
 return el("div", { class = "gp-header", key = "header" }, parts)
end

return M
