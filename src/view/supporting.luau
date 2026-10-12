--!strict
-- The changed files no step visits as a folder tree, each file foldable with its own reviewed tick.
-- Tests and generated files follow the others, each under a folded group row.
local Code = require("./code")
local Comments = require("./comments")
local FileGroup = require("../file-group")
local FileTree = require("../file-tree")
local Pr = require("../pr")
local Review = require("../review")
local State = require("../state")
local Text = require("../text")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

-- Estimated heights (px) for the unroll animation: a folder row, a file header with its margin.
local GROUP_H, FILE_HEAD_H = 28, 45
-- Indents deeper than this line up with it.
local MAX_DEPTH = 8

local M = {}

function M.fileKey(path: string): string
 return "f-" .. Text.keyOf(path)
end

local function heading(s: State.State, files: { Pr.File }): Node
 local viewed, openable, allOpen = 0, 0, true
 for _, file in files do
  if s.review.filesViewed[file.path] then viewed += 1 end
  -- "Open all" leaves generated files alone, so they don't count for it.
  if file.group == "generated" then continue end
  openable += 1
  if not (s.supportingOpen and s.fileOpen[file.path]) then allOpen = false end
  if file.group == "tests" and s.foldedFolders[FileGroup.foldKey("tests")] then allOpen = false end
 end
 local allViewed = viewed == #files
 local kids = {
  el("div", { class = "gp-sup-head", actions = { click = "toggle-group" } }, {
   Ui.caret(s.supportingOpen),
   span("gp-sup-title", "Supporting changes"),
   span("gp-sup-sub", #files .. " files that follow from the changes above · " .. viewed .. " reviewed"),
  }),
  Ui.spacer(),
 }
 if openable > 0 then
  table.insert(kids, Ui.actionLink(if allOpen then "Close all" else "Open all", "o", "open-all-supporting", false))
 end
 table.insert(kids, Ui.actionLink(if allViewed then "All " .. #files .. " reviewed" else "Mark all " .. #files .. " reviewed", "⇧ S", "mark-supporting", allViewed))
 return el("div", { class = "gp-sup-row", key = "head" }, kids)
end

local function fileBlock(s: State.State, motion: Ui.Motion, plan: State.Plan, file: Pr.File, depth: string): (Node, number)
 local path = file.path
 local blockId = State.supportingBlock(path)
 local open = plan.open[blockId] == true
 local viewed = s.review.filesViewed[path] == true
 local children = { Code.head(s, file, {
  toggle = "toggle-file=" .. path,
  expanded = open,
  blockId = blockId,
  done = viewed,
  check = Ui.check(viewed, "Reviewed", "mark-file=" .. path),
 }) }
 local height = FILE_HEAD_H
 if open then
  local fd = s.diffs[path]
  local show = State.show(s, path, blockId, nil)
  local rows, rowsHeight = Code.rows(s, fd, blockId, show, plan.plain[blockId] == true, Comments.forBlock(s, motion, path, blockId, false))
  table.insert(children, Ui.body(motion, "file:" .. path, s.closing["file:" .. path] == true, rowsHeight, rows))
  height += rowsHeight
 end
 return el("div", { class = "gp-sfile gp-sup-indent" .. depth, key = M.fileKey(path) }, children), height
end

-- The row that folds a group: its name and how many files it holds.
local function groupRow(s: State.State, section: FileTree.Section, group: FileGroup.Group): Node
 local folded = s.foldedFolders[FileGroup.foldKey(group)] == true
 return el("div", { class = "gp-tree-row gp-tree-folder gp-sup-folder", key = "g-" .. group, actions = { click = "toggle-folder=" .. FileGroup.foldKey(group) } }, {
  el("span", { class = "gp-tree-glyph" }, { Ui.icon(if folded then "chev-r" else "chev") }),
  el("span", { class = "gp-tree-go" }, {
   Ui.icon(if folded then "folder" else "folder-open"),
   span("gp-tree-folder-name", FileGroup.LABELS[group]),
   span("gp-sup-count", tostring(#section.files)),
  }),
 })
end

local function groups(s: State.State, motion: Ui.Motion, plan: State.Plan, sections: { FileTree.Section }): ({ Node }, number)
 local nodes, height = {}, 0
 for _, section in sections do
  -- A group's files sit one level in under its row, and its folded state hides them all.
  local inset = 0
  local group = section.group
  if group then
   table.insert(nodes, groupRow(s, section, group))
   height += GROUP_H
   if s.foldedFolders[FileGroup.foldKey(group)] then continue end
   inset = 1
  end
  local scope = group or "plain"
  for _, row in section.rows do
   local parent = string.match(if row.kind == "folder" then row.path else row.file.path, "^(.*)/[^/]*$")
   if parent and State.inFoldedFolder(s, parent .. "/") then continue end
   local depth = " gp-tree-d" .. math.min(row.depth + inset, MAX_DEPTH)
   if row.kind == "folder" then
    local folded = s.foldedFolders[row.path] == true
    table.insert(nodes, el("div", { class = "gp-tree-row gp-tree-folder gp-sup-folder" .. depth, key = "d-" .. scope .. "-" .. Text.keyOf(row.path), actions = { click = "toggle-folder=" .. row.path } }, {
     el("span", { class = "gp-tree-glyph" }, { Ui.icon(if folded then "chev-r" else "chev") }),
     el("span", { class = "gp-tree-go" }, { Ui.icon(if folded then "folder" else "folder-open"), span("gp-tree-folder-name", row.name) }),
    }))
    height += GROUP_H
   else
    local node, fileHeight = fileBlock(s, motion, plan, row.file, depth)
    table.insert(nodes, node)
    height += fileHeight
   end
  end
 end
 if plan.supportingFolded > 0 then
  local n = plan.supportingFolded
  table.insert(nodes, el("div", { class = "gp-sup-folded", key = "folded", text = n .. " more " .. (if n == 1 then "file" else "files") .. " folded to keep the page fast · open one from its header" }))
  height += GROUP_H
 end
 return nodes, height
end

-- Nil when every changed file is visited by a step.
function M.view(s: State.State, motion: Ui.Motion, plan: State.Plan): Node?
 local files = Review.supportingFiles(s.review)
 if #files == 0 then return nil end
 local nodes = { heading(s, files) }
 if s.supportingOpen then
  local inner, height = groups(s, motion, plan, Review.supportingSections(s.review))
  table.insert(nodes, Ui.body(motion, "group", s.closing.group == true, height, inner))
 end
 return el("div", { class = "gp-supporting", key = "supporting" }, nodes)
end

return M
