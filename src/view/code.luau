--!strict
-- Code blocks: a file header pinned while its code scrolls, then diff lines with hidden runs as gap
-- bars, comment cards under their lines, and long unchanged stretches of big files drawn natively.
local Comments = require("./comments")
local Diff = require("../diff")
local Guide = require("../guide")
local Pr = require("../pr")
local Review = require("../review")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

export type Head = {
 -- The range label beside the path.
 label: string?,
 -- What a click on the path does.
 toggle: string,
 expanded: boolean,
 blockId: string,
 done: boolean,
 check: Node,
}

-- How a block marks its steps: the entries of the step you are on, which are highlighted (and
-- pulse with `pulse` after a jump to it), and for a block of several steps where each starts, so
-- its number sits in the gutter there.
export type Marks = {
 on: Diff.Interval?,
 pulse: string?,
 starts: { [number]: Start }?,
}
export type Start = { n: number, position: number, here: boolean }

local el, span = Ui.el, Ui.span

-- Layout estimates (px) measured in Tern; they size the unroll animation.
local ROW_H, GAP_H = 19, 26
local SIGNS = { add = "+", del = "-", ctx = " " }

local M = {}

function M.head(s: State.State, file: Pr.File, head: Head): Node
 local kids = {
  el("span", { class = "gp-fpath", actions = { click = head.toggle } }, {
   el("span", { class = "gp-fcaret" }, { Ui.icon(if head.expanded then "chev" else "chev-r") }),
   span("gp-fdir", Text.dirName(file.path)),
   span("gp-fbase", Text.baseName(file.path)),
  }),
  span("gp-frange", head.label or ""),
  Ui.spacer(),
 }
 -- No diff rows: a binary file, or one renamed without changes, as GitHub says instead of "+0 −0".
 if #file.rows == 0 then
  table.insert(kids, span("gp-frange", if file.status == "renamed" then "Renamed without changes" elseif file.status == "added" then "Empty file" else "Binary file not shown"))
 else
  table.insert(kids, span("gp-adds", "+" .. file.adds))
  table.insert(kids, span("gp-dels", "−" .. file.dels))
 end
 if head.expanded and file.src then
  table.insert(kids, el("span", {
   class = "gp-wholefile",
   text = if s.whole[head.blockId] then "Show only the diff" else "Show whole file",
   actions = { click = "whole=" .. head.blockId },
  }))
 end
 table.insert(kids, head.check)
 return el("div", { class = "gp-fhead" .. (if head.done then " gp-fhead-done" else ""), key = "fhead" }, kids)
end

-- The line's code: colored pieces, or its text alone when the block draws `plain` or the file
-- has no syntax.
local function codeSpan(fd: Diff.FileDiff, i: number, plain: boolean): Node
 if plain or not fd.syntax then return el("span", { class = "gp-code", text = fd.entries[i].row.text }) end
 return Ui.tokens(Diff.tokens(fd, i))
end

-- One diff line. New-side lines of the PR's diff carry a "+" that shows on hover and opens a
-- comment there; GitHub takes comments only on those. `selected` tints lines inside the range being
-- commented on; `hit` marks a search result; `marks` highlights the step you are on and numbers
-- the steps of a shared block in the gutter.
local function lineRow(fd: Diff.FileDiff, i: number, plain: boolean, selected: boolean, hit: boolean, marks: Marks?): Node
 local entry = fd.entries[i]
 local row = entry.row
 local on = marks ~= nil and marks.on ~= nil and i >= marks.on.first and i <= marks.on.last
 local class = "gp-row " .. (if entry.moved then "gp-moved" else "gp-" .. row.kind)
  .. (if on then " gp-on" .. (if marks and marks.pulse then " " .. marks.pulse else "") else "")
  .. (if selected then " gp-selected" else "") .. (if hit then " gp-hit" else "")
 local kids = {}
 if marks and marks.starts then
  local start = marks.starts[i]
  if start then
   table.insert(kids, el("span", { class = "gp-mk gp-mk-n" .. (if start.here then " gp-mk-here" else ""), text = tostring(start.n), actions = { click = "goto-step=" .. start.position } }))
  else
   table.insert(kids, span("gp-mk", ""))
  end
 end
 table.insert(kids, if row.new and entry.diff then el("span", { class = "gp-plus", text = "+", actions = { click = "comment=" .. fd.file.path .. "|" .. row.new } }) else span("gp-plus-none", ""))
 table.insert(kids, span("gp-gut", if row.old then tostring(row.old) else ""))
 table.insert(kids, span("gp-gut", if row.new then tostring(row.new) else ""))
 table.insert(kids, span("gp-sign", SIGNS[row.kind]))
 table.insert(kids, codeSpan(fd, i, plain))
 return el("div", { class = class, key = "r" .. i }, kids)
end

-- The quiet line above the first shown line of a moved block, in the gutter columns of a code row
-- so the text lines up with the code: where the other half of the block is.
local function movedLabel(fd: Diff.FileDiff, i: number, marks: Marks?): Node
 local entry = fd.entries[i]
 local moved = entry.moved :: Diff.Move
 local verb = if entry.row.kind == "del" then "Moved to" else "Moved from"
 local where = if moved.path == fd.file.path then "line " .. moved.line else moved.path .. ":" .. moved.line
 local kids = {}
 if marks and marks.starts then table.insert(kids, span("gp-mk", "")) end
 table.insert(kids, span("gp-plus-none", ""))
 table.insert(kids, span("gp-gut", ""))
 table.insert(kids, span("gp-gut", ""))
 table.insert(kids, span("gp-sign", ""))
 table.insert(kids, span("gp-moved-text", verb .. " " .. where))
 local on = marks ~= nil and marks.on ~= nil and i >= marks.on.first and i <= marks.on.last
 return el("div", { class = "gp-moved-label" .. (if on then " gp-on" else ""), key = "m" .. i }, kids)
end

-- A run of hidden unchanged lines as one quiet bar; a click opens its `reveal` lines.
local function gapRow(blockId: string, gap: Diff.Gap): Node
 local kids = {
  span("gp-gap-gut", gap.arrow),
  span("gp-gap-count", gap.hidden .. " unchanged " .. (if gap.hidden == 1 then "line" else "lines")),
 }
 if gap.label then table.insert(kids, span("gp-gap-label", gap.label)) end
 return el("div", { class = "gp-gap", key = "gap" .. gap.first, actions = { click = "reveal=" .. blockId .. "|" .. gap.reveal.first .. "|" .. gap.reveal.last } }, kids)
end

-- Tern's code viewer only draws the lines on screen, so a long unchanged run costs one node.
local function nativeRun(fd: Diff.FileDiff, run: Diff.Native): Node
 return el("div", { class = "gp-native", key = "n" .. run.first }, {
  tern.ui.code(Diff.runText(fd, run.first, run.last), fd.language, fd.entries[run.first].row.new),
 })
end

-- The rows of block `blockId` on `fd` showing `show`, uncolored when `plain`, and their estimated
-- height. Each unbroken run of lines scrolls sideways on its own, so long lines can be read while
-- comment cards and gap bars keep the block's width. `starts` says which run each line is in (see
-- State.runStarts), and `marks` is how a step block marks its steps.
function M.rows(s: State.State, fd: Diff.FileDiff, blockId: string, show: Diff.Show, plain: boolean, cards: Comments.Cards, starts: { [number]: number }, marks: Marks?): ({ Node }, number)
 local path = fd.file.path
 if fd.file.binary then
  return { el("div", { class = "gp-gap", key = "binary" }, { span("gp-gap-count", "Binary file, not shown") }) }, GAP_H
 end
 local hit = show.hit
 local c = if s.composer and s.composer.file == path then s.composer else nil
 local segments = Diff.layout(fd, show).segments
 local rows, height = {}, 0
 local lines: { Node }, firstLine = {}, 0
 local function flush()
  if #lines == 0 then return end
  table.insert(rows, el("div", { class = "gp-hscroll", key = "h" .. firstLine }, { el("div", { class = "gp-hlines", key = "l" }, lines) }))
  lines = {}
 end
 for _, segment in segments do
  if segment.kind == "rows" then
   for i = segment.first, segment.last do
    local line = fd.entries[i].row.new
    local selected = c ~= nil and line ~= nil and line >= c.from and line <= c.to
    if starts[i] ~= firstLine then flush() end
    firstLine = starts[i]
    local moved = fd.entries[i].moved
    if moved and (moved.start or i == segment.first) then
     table.insert(lines, movedLabel(fd, i, marks))
     height += ROW_H
    end
    table.insert(lines, lineRow(fd, i, plain, selected, hit == i, marks))
    height += ROW_H
    local slot = if line then cards[line] else nil
    if slot then
     flush()
     for _, node in slot.nodes do table.insert(rows, node) end
     height += slot.height
    end
   end
  elseif segment.kind == "native" then
   flush()
   table.insert(rows, nativeRun(fd, segment))
   height += (segment.last - segment.first + 1) * ROW_H
  else
   flush()
   table.insert(rows, gapRow(blockId, segment))
   height += GAP_H
  end
 end
 flush()
 return rows, height
end

-- How a range of lines reads in a block's header.
local function rangeLabel(step: Guide.Step): string
 local noun = if step.side == "old" then "removed line" else "line"
 if step.from == step.to then return noun .. " " .. step.from end
 return noun .. "s " .. step.from .. "–" .. step.to
end

-- What the header says of the steps a block shows: the one you are on among its change's steps with
-- its lines, or for a block you are not on, which steps it holds. Nil without a guide.
local function blockLabel(s: State.State, block: Guide.Block, current: Guide.Step?): string?
 if not s.review.guide.guided then return nil end
 local steps = block.steps
 if #steps == 1 then return rangeLabel(steps[1]) end
 if current then
  return "Step " .. current.index .. " of " .. #s.review.guide.changes[current.change].steps .. "  ·  " .. rangeLabel(current)
 end
 return "Steps " .. steps[1].index .. "–" .. steps[#steps].index
end

-- The marks of a guided block that is drawn open: the step you are on highlighted, and where
-- each step of a shared block starts.
local function marksOf(s: State.State, block: Guide.Block, current: Guide.Step?): Marks
 local marks: Marks = {}
 if current then
  marks.on = s.spans[current]
  if marks.on and s.flashStep == current.key then marks.pulse = "gp-pulse" .. (s.flashCount % 2) end
 end
 if #block.steps > 1 then
  local starts = {}
  for _, step in block.steps do
   local span = s.spans[step]
   if span then
    starts[span.first] = starts[span.first] or { n = step.index, position = step.position, here = step == current }
   end
  end
  marks.starts = starts
 end
 return marks
end

-- One code block: a run of consecutive steps' lines and a couple either side, folded once all are
-- reviewed or when `plan` leaves it folded. The step you are on has its lines highlighted, and the
-- block holding it keeps a steady outline. A shared block's Reviewed ticks the step you are on.
function M.block(s: State.State, motion: Ui.Motion, plan: State.Plan, block: Guide.Block): Node
 local id = block.id
 local r = s.review
 local fd = s.diffs[block.file]
 local reviewed = Review.blockReviewed(r, id)
 local open = plan.open[id] == true
 local cursor = State.currentStep(s)
 local here = cursor.block == id
 local current = if here then cursor else nil
 local check
 if #block.steps > 1 and current then
  check = Ui.check(r.reviewed[current.key] == true, "Step " .. current.index .. " reviewed", "review-step=" .. current.key, "⏎")
 elseif #block.steps > 1 then
  check = Ui.check(reviewed, "Reviewed", "mark-block=" .. id, nil)
 else
  -- ⏎ ticks the step you are on, so only its block shows it.
  check = Ui.check(reviewed, "Reviewed", "review-step=" .. block.steps[1].key, if here then "⏎" else nil)
 end
 local head = M.head(s, fd.file, {
  label = blockLabel(s, block, current),
  toggle = "peek=" .. id,
  expanded = open,
  blockId = id,
  done = reviewed,
  check = check,
 })
 -- The landing flash alternates two identical animations so landing on the same block replays it.
 local flash = if s.flash == id then " gp-flash" .. (s.flashCount % 2) else ""
 local class = "gp-excerpt" .. flash .. (if here then " gp-current" else "")
 if not open then
  return el("div", { class = class .. " gp-excerpt-done", key = id }, { head })
 end
 local show = State.show(s, block.file, id, block.steps)
 local marks = if r.guide.guided then marksOf(s, block, current) else nil
 local starts = State.runStarts(s, block.file, id, block.steps, show)
 local rows, height = M.rows(s, fd, id, show, plan.plain[id] == true, Comments.forBlock(s, motion, block.file, id, true), starts, marks)
 return el("div", { class = class, key = id }, { head, Ui.body(motion, "x:" .. id, s.closing["peek:" .. id] == true, height, rows) })
end

return M
