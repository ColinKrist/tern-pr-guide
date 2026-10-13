--!strict
-- The left column beside one change: its place and reviewed tick, why, its files, then its steps.
-- Without a guide it is the PR's changed files as a folder tree instead.
-- Every change's row carries its own card pinned with position: sticky, so scrolling into the next
-- row swaps in the next card: Tern gives plugins no scroll events to drive one shared copy.
local FileGroup = require("../file-group")
local FileTree = require("../file-tree")
local Guide = require("../guide")
local Review = require("../review")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local M = {}

-- A step's tick: a check once reviewed, an empty circle until then.
local function tick(reviewed: boolean, class: string, action: string): Node
 if reviewed then return el("span", { class = class, actions = { click = action } }, { Ui.icon("check") }) end
 return el("span", { class = class, text = "○", actions = { click = action } })
end

local function fileList(r: Review.Review, change: number): { Node }
 local list = {}
 for _, file in Review.filesOfChange(r, change) do
  table.insert(list, el("div", { class = "gp-cfile", key = "cf-" .. Text.keyOf(file.path), actions = { click = "goto-step=" .. Review.firstStep(r, change, file.path) } }, {
   Ui.fileIcon(file.path),
   span("gp-cfile-name", Text.baseName(file.path)),
   span("gp-cfile-dir", Text.dirName(file.path)),
   Ui.spacer(),
   span("gp-adds gp-num-adds", if file.adds > 0 then "+" .. file.adds else ""),
   span("gp-dels gp-num-dels", if file.dels > 0 then "−" .. file.dels else ""),
  }))
 end
 return list
end

-- A change with more steps than this lists only the few around the one you are on, so the pinned
-- card stays within the screen with the current step on it: Tern gives plugins no way to scroll a
-- nested scroller to a node without moving the page too.
local MAX_LISTED = 7
local AROUND = 2

-- The first and last step listed for a change of `count` steps while on step `at`.
local function listed(count: number, at: number): (number, number)
 if count <= MAX_LISTED then return 1, count end
 local first = math.clamp(at - AROUND, 1, count - 2 * AROUND)
 return first, first + 2 * AROUND
end

local function more(count: number, word: string, key: string): Node
 return el("div", { class = "gp-ol-more", key = key, text = count .. " " .. word .. " " .. (if count == 1 then "step" else "steps") })
end

-- The step you are on sits in a tinted box with its note, matching the outlined code block.
local function stepList(r: Review.Review, change: Guide.Change, current: Guide.Step): { Node }
 local steps = {}
 local first, last = listed(#change.steps, if current.change == change.steps[1].change then current.index else 1)
 if first > 1 then table.insert(steps, more(first - 1, "earlier", "before")) end
 for i = first, last do
  local step = change.steps[i]
  local key = step.key
  local here = step == current
  local kids = { tick(r.reviewed[key] == true, "gp-ol-dot", "review-step=" .. key) }
  -- The number the step has on its lines when a block holds several steps.
  if #change.steps > 1 then table.insert(kids, span("gp-ol-num", tostring(step.index))) end
  table.insert(kids, el("span", { class = "gp-ol-steptitle", text = step.title, actions = { click = "goto-step=" .. step.position } }))
  local row = el("div", { class = "gp-ol-step" .. (if here then " gp-ol-here" else ""), key = "os" .. key }, kids)
  if here then
   table.insert(steps, el("div", { class = "gp-ol-herebox" .. (if #change.steps > 1 then " gp-ol-numbered" else ""), key = "hb" .. key }, {
    row,
    el("div", { class = "gp-ol-stepbody", key = "ob" .. key }, { Ui.rich(step.note) }),
   }))
  else
   table.insert(steps, row)
  end
 end
 if last < #change.steps then table.insert(steps, more(#change.steps - last, "more", "after")) end
 return steps
end

-- About how many characters of the why fit on a line of the card.
local WHY_CHARS = 40

-- Indents deeper than this line up with it.
local MAX_DEPTH = 8

-- The unguided page's one step per file: a GitHub-style tree whose file rows tick and jump like
-- steps, and whose folders fold on a click. A folded folder hiding the file you are on is marked.
-- Tests and generated files come last, each under a row that folds the group.
local function fileTree(s: State.State): Node
 local r = s.review
 local stepOf: { [string]: Guide.Step } = {}
 for _, step in r.steps do stepOf[step.file] = step end
 local current = State.currentStep(s)
 local rows = {}
 for _, section in FileTree.sections(r.pr.files) do
  local inset, group = 0, section.group
  if group then
   local folded = s.foldedFolders[FileGroup.foldKey(group)] == true
   local holds = folded and s.diffs[current.file].file.group == group
   table.insert(rows, el("div", { class = "gp-tree-row gp-tree-folder" .. (if holds then " gp-tree-holds" else ""), key = "tg-" .. group, actions = { click = "toggle-folder=" .. FileGroup.foldKey(group) } }, {
    el("span", { class = "gp-tree-glyph" }, { Ui.icon(if folded then "chev-r" else "chev") }),
    el("span", { class = "gp-tree-go" }, { Ui.icon(if folded then "folder" else "folder-open"), span("gp-tree-folder-name", FileGroup.LABELS[group]), span("gp-sup-count", tostring(#section.files)) }),
   }))
   if folded then continue end
   inset = 1
  end
  local scope = group or "plain"
  -- The depth of the folded folder whose contents are being skipped.
  local hiddenBelow = math.huge
  for _, row in section.rows do
   if row.depth > hiddenBelow then continue end
   hiddenBelow = math.huge
   local depth = " gp-tree-d" .. math.min(row.depth + inset, MAX_DEPTH)
   if row.kind == "folder" then
    local folded = s.foldedFolders[row.path] == true
    if folded then hiddenBelow = row.depth end
    local holds = folded and string.sub(current.file, 1, #row.path + 1) == row.path .. "/"
    table.insert(rows, el("div", { class = "gp-tree-row gp-tree-folder" .. depth .. (if holds then " gp-tree-holds" else ""), key = "td-" .. scope .. "-" .. Text.keyOf(row.path), actions = { click = "toggle-folder=" .. row.path } }, {
     el("span", { class = "gp-tree-glyph" }, { Ui.icon(if folded then "chev-r" else "chev") }),
     el("span", { class = "gp-tree-go" }, { Ui.icon(if folded then "folder" else "folder-open"), span("gp-tree-folder-name", row.name) }),
    }))
   else
    local file = row.file
    local step = stepOf[file.path]
    local here = step == current
    table.insert(rows, el("div", { class = "gp-tree-row gp-tree-file" .. depth .. (if here then " gp-tree-here" else ""), key = "tf-" .. Text.keyOf(file.path) }, {
     tick(r.reviewed[step.key] == true, "gp-tree-glyph gp-tree-tick", "review-step=" .. step.key),
     el("span", { class = "gp-tree-go", actions = { click = "goto-step=" .. step.position } }, {
      Ui.fileIcon(file.path),
      span("gp-cfile-name", Text.baseName(file.path)),
      Ui.spacer(),
      span("gp-adds gp-num-adds", if file.adds > 0 then "+" .. file.adds else ""),
      span("gp-dels gp-num-dels", if file.dels > 0 then "−" .. file.dels else ""),
     }),
    }))
   end
  end
 end
 return el("div", { class = "gp-outline gp-ccard gp-tree", key = "outline" }, {
  el("div", { class = "gp-tree-head" }, {
   span("gp-band-label", #r.steps .. " " .. (if #r.steps == 1 then "file" else "files") .. " changed"),
   Ui.spacer(),
   M.treeToggle(),
  }),
  el("div", { class = "gp-tree-rows" }, rows),
 })
end

-- The button that hides the file view's tree, and shows it again from the rail left in its place.
function M.treeToggle(): Node
 return el("span", { class = "gp-tree-toggle", key = "toggle", actions = { click = "toggle-tree" } }, { Ui.icon("sidebar"), Ui.keys("b") })
end

function M.view(s: State.State, n: number): Node
 local r = s.review
 if not r.guide.guided then return fileTree(s) end
 local change = r.guide.changes[n]
 local keys = Review.keysOfChange(r, n)
 local done = Review.reviewedCount(r, keys)
 local all = done == #keys
 local meta = { Ui.check(all, "Reviewed", "mark-change=" .. n) }
 if not all and #keys > 1 then table.insert(meta, span("gp-band-steps", done .. " of " .. #keys .. " steps done")) end
 table.insert(meta, Ui.keys("⇧ ⏎"))
 return el("div", { class = "gp-outline gp-sticky gp-ccard", key = "outline" }, {
  span("gp-band-label", "Change " .. n .. " of " .. #r.guide.changes),
  span("gp-band-title" .. (if #change.title > 60 then " gp-band-title-long" else ""), change.title),
  el("div", { class = "gp-band-meta" }, meta),
  -- A long why and a long file list give way first when the card would pass the screen, then a long
  -- title, each keeping a few lines and a scroll of its own.
  el("div", { class = "gp-band-why" .. (if Text.wrappedLines(change.why, WHY_CHARS) > 3 then " gp-band-why-long" else "") }, { Ui.rich(change.why) }),
  el("div", { class = "gp-cfiles" .. (if #Review.filesOfChange(r, n) > 3 then " gp-cfiles-long" else "") }, fileList(r, n)),
  span("gp-ccard-h", "Steps"),
  el("div", { class = "gp-ccard-steps" }, stepList(r, change, State.currentStep(s))),
 })
end

return M
