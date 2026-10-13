--!strict
-- The page: header, description, overview, each change's card beside its code, the supporting
-- files, and the hint bar. Also the node paths the page scrolls to and focuses, which follow these keys. Each path starts at the page's root,
-- the node path its host mounts the page under ("main" for the guide block).
local Agent = require("../agent")
local Change = require("./change")
local Code = require("./code")
local Comments = require("./comments")
local Description = require("./description")
local Guide = require("../guide")
local Header = require("./header")
local Hints = require("./hints")
local ModelPanel = require("./model-panel")
local Overview = require("./overview")
local Review = require("../review")
local ReviewPanel = require("./review-panel")
local State = require("../state")
local Supporting = require("./supporting")
local Ui = require("./ui")

local el = Ui.el

-- How many blocks stagger in when an AI guide arrives; later ones come with the last.
local STAGGERED_BLOCKS = 6

local M = {}

-- Everything that fades colors or borders between states (a card added, a block marked reviewed)
-- does so only under `gp-soft`, which the page drops once a key drives it: keys stay instant.
local function rootClass(s: State.State, extra: string): string
 return "gp-root gp-page" .. extra .. (if s.keyed then "" else " gp-soft")
end

-- Adds `class` to `node`'s classes.
local function addClass(node: Node, class: string)
 local props = (node :: any).p
 props.class = props.class .. " " .. class
end

-- Marks the page's blocks as arriving. A PR that just opened fades in as a whole; a guide the AI
-- just finished writing, the rare moment of a review, has the blocks below the header rise in one
-- after another. The classes stay for the page's life: they only play when their node is drawn.
local function arriving(s: State.State, blocks: { Node })
 if s.arrival == "still" then return end
 if s.arrival == "guide" then
  for n = 1, #blocks do addClass(blocks[n], "gp-arrive gp-ad" .. math.min(n, STAGGERED_BLOCKS)) end
 else
  for _, block in blocks do addClass(block, "gp-arrive-load") end
 end
end

-- The page: its header and hint bar pinned around a body that scrolls. They sit outside the body, not sticky in it: Tern
-- leaves a sticky node out of paint after a `reveal` until the next wheel scroll, and the review panel lives in the header.
local function pageFit(s: State.State, motion: Ui.Motion, extra: string, body: { Node }): Node
 return el("div", {}, {
  el("div", { class = rootClass(s, extra .. " gp-page-fit"), key = "page" }, {
   Header.view(s, motion),
   el("div", { class = "gp-page-body", key = "body" }, body),
   Hints.view(s),
  }),
 })
end

-- Without a guide, or in the file view of a PR that has one: the header, then the file tree pinned
-- beside the code with a scroll of its own (or, hidden, a rail with the button that shows it),
-- and the description at the top of the code. The code scrolls with the page body (see `pageFit`). Keys
-- match the guided page's first change row, so block paths are the same.
local function split(s: State.State, motion: Ui.Motion, plan: State.Plan): Node
 local blocks = { Description.view(s, motion) }
 for _, block in Guide.blocks(s.review.steps) do table.insert(blocks, Code.block(s, motion, plan, block)) end
 local main = {
  el("div", { class = "gp-split-row", key = "ch1" }, {
   if s.treeHidden
    then el("div", { class = "gp-split-rail", key = "rail" }, { Change.treeToggle() })
    else el("div", { class = "gp-split-left", key = "tree" }, { Change.view(s, 1) }),
   el("div", { class = "gp-code-col gp-split-right", key = "code" }, blocks),
  }),
 }
 arriving(s, main)
 return pageFit(s, motion, " gp-split", main)
end

function M.view(s: State.State, motion: Ui.Motion): Node
 local plan = State.plan(s)
 if not s.review.guide.guided then return split(s, motion, plan) end
 local page = { Description.view(s, motion) }
 local overview = Overview.view(s, motion)
 if overview then table.insert(page, overview) end
 for n, change in s.review.guide.changes do
  local blocks = {}
  for _, block in Guide.blocks(change.steps) do table.insert(blocks, Code.block(s, motion, plan, block)) end
  table.insert(page, el("div", { class = "gp-guide gp-crow", key = "ch" .. n }, {
   Change.view(s, n),
   el("div", { class = "gp-code-col", key = "code" }, blocks),
  }))
 end
 local supporting = Supporting.view(s, motion, plan)
 if supporting then
  table.insert(page, el("div", { class = "gp-crow", key = "sup" }, { el("div", { class = "gp-code-col", key = "code" }, { supporting }) }))
 end
 arriving(s, page)
 return pageFit(s, motion, "", page)
end

-- The page's scrolling body under `root`: every path below starts there, and scroll ops target it.
local function pagePath(root: string): string
 return root .. ".page.body"
end

-- What the wheel, Home and End scroll: the page body, or without a guide the code column beside the
-- file tree, which scrolls on its own.
function M.scrollPath(s: State.State): string
 return if s.review.guide.guided then pagePath(s.root) else pagePath(s.root) .. ".ch1.code"
end

-- The header pinned above the body: title row, search, review panel and model button.
local function headerPath(root: string): string
 return root .. ".page.header"
end

-- The code block `blockId`: a step's block in its change row, or a supporting file's.
function M.blockPath(root: string, blockId: string): string
 local PAGE = pagePath(root)
 local file = State.supportingPath(blockId)
 if file then return PAGE .. ".sup.code.supporting.body." .. Supporting.fileKey(file) end
 return PAGE .. ".ch" .. (string.match(blockId, "^c(%d+)s") :: string) .. ".code." .. blockId
end

-- The supporting changes' section.
function M.supportingPath(root: string): string
 return pagePath(root) .. ".sup"
end

-- Where a jump to block `blockId` lands it: an open block's body, which the body's scroll padding
-- leaves clear for the block's sticky header, so the whole block shows; a folded block itself.
function M.topPath(s: State.State, blockId: string): string
 local path = M.blockPath(s.root, blockId)
 return if State.plan(s).open[blockId] then path .. ".body" else path
end

-- The first run of code lines of step `step` in its shared block, which starts at entry `first`.
function M.stepPath(root: string, step: Guide.Step, first: number): string
 return M.blockPath(root, step.block) .. ".body.h" .. first
end

-- The diff line `entry` of a block: inside the run of lines the block draws it in (State.runStarts).
-- Nil when the block doesn't draw it.
function M.linePath(s: State.State, blockId: string, entry: number): string?
 local file = State.supportingPath(blockId)
 local steps = if file then nil else Review.stepsOfBlock(s.review, blockId)
 if steps then file = if #steps > 0 then steps[1].file else nil end
 if not file then return nil end
 local first = State.runStarts(s, file, blockId, steps, State.show(s, file, blockId, steps))[entry]
 if not first then return nil end
 return M.blockPath(s.root, blockId) .. ".body.h" .. first .. ".l.r" .. entry
end

function M.suggestionPath(root: string, blockId: string, id: string): string
 return M.blockPath(root, blockId) .. ".body." .. Comments.suggestionKey(id)
end

function M.composerPath(root: string, blockId: string): string
 return M.blockPath(root, blockId) .. ".body.composer"
end

function M.composerFieldPath(root: string, blockId: string): string
 return M.composerPath(root, blockId) .. ".body.field"
end

function M.searchFieldPath(root: string): string
 return headerPath(root) .. ".search.box.field"
end

-- The Guided | Files tabs in the title row; their select events carry this id.
function M.viewTabsPath(root: string): string
 return headerPath(root) .. ".title.views.tabs"
end

-- Result `n` of the open search, in the header's list.
function M.searchRowPath(root: string, n: number): string
 return headerPath(root) .. ".search.list.r" .. n
end

-- The layer region's nodes sit under "layer", beside the page's root.
local LAYER = "layer"
M.modelFieldPath = LAYER .. ".models.body.box.field"

-- The layer: while the model menu is open, a scrim that closes it on a click anywhere outside, and
-- the menu as an overlay under the Settings button.
function M.layer(s: State.State): Node?
 local run, box = s.ai, s.models
 if not run or not box or Agent.busy(run) then return nil end
 return el("div", {}, {
  el("div", { class = "gp-md-scrim", key = "scrim", actions = { click = "toggle-models" } }),
  ModelPanel.view(box, run.agent, headerPath(s.root) .. ".status.settings", not s.keyed),
 })
end

function M.summaryFieldPath(root: string): string
 return headerPath(root) .. ".review.cols.side.summary.field"
end

-- A verdict's row, and the submit button (or the posted card in its place), in the review panel's side column.
function M.verdictPath(root: string, id: string): string
 return headerPath(root) .. ".review.cols.side.verdicts.v-" .. id
end

function M.submitPath(root: string): string
 return headerPath(root) .. ".review.cols.side.submit"
end

function M.reviewRowPath(root: string, item: Review.Item): string
 return headerPath(root) .. ".review.cols.list." .. ReviewPanel.rowKey(item)
end

return M
