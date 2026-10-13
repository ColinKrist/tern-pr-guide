--!strict
-- Every shortcut, grouped in the order a review goes: read, react, finish.
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

type Group = { title: string, keys: { { string } } }

-- What the page shows: a guided walkthrough or the plain file list, and whether the reader can
-- switch between the two (a PR with a guide).
export type Kind = { guided: boolean, switch: boolean, hosted: State.Hosted? }

local GUIDED: { Group } = {
 { title = "1  Read", keys = { { "j  k", "next / previous step" }, { "n  p", "next / previous suggestion" }, { "/", "search the PR" }, { "i", "PR description" }, { "s", "supporting changes" }, { "o", "open supporting files, not generated ones" }, { "⇧ S", "mark supporting files reviewed" }, { "g", "open on GitHub" } } },
 { title = "2  React", keys = { { "⏎", "step reviewed, move on" }, { "⇧ ⏎", "whole change reviewed" }, { "f", "whole file reviewed" }, { "m", "mark / unmark all reviewed" }, { "a  d", "add / dismiss suggestion" }, { "c", "comment on this step" } } },
 { title = "3  Finish", keys = { { "r", "open your review" }, { "j  k", "move between comments" }, { "x", "include or leave out" }, { "a", "include / exclude all" }, { "e", "edit the summary" }, { "1 2 3", "comment, approve, request changes" }, { "⌘ ⏎", "submit" }, { "esc", "close the review" } } },
}

-- A plain file list: every step is a whole file and there is one change, the whole PR. With no
-- guide the generate key is offered; with one, `n  p` and `a  d` walk its suggested comments.
local FILES: { Group } = {
 { title = "1  Read", keys = { { "j  k", "next / previous file" }, { "/", "search the PR" }, { "i", "PR description" }, { "b", "hide / show the file tree" }, { "g", "open on GitHub" } } },
 { title = "2  React", keys = { { "⏎", "file reviewed, move on" }, { "m", "mark / unmark all reviewed" }, { "c", "comment on this file" } } },
 GUIDED[3],
}

local function groups(kind: Kind): { Group }
 local source = if kind.guided then GUIDED else FILES
 local out: { Group } = {}
 for _, group in source do
  local keys = table.clone(group.keys)
  if group.title == "1  Read" then
   if kind.hosted and kind.hosted.fixes then
    table.insert(keys, 1, { "t", "next view: fixes, guided, files" })
    if kind.switch and not kind.guided then table.insert(keys, 2, { "n  p", "next / previous suggestion" }) end
   elseif kind.switch then
    table.insert(keys, 1, { "t", if kind.guided then "switch to the file view" else "switch to the guided view" })
    if not kind.guided then table.insert(keys, 2, { "n  p", "next / previous suggestion" }) end
   end
   if not kind.switch then table.insert(keys, { "⇧ G", "generate AI guide" }) end
   if kind.hosted then table.insert(keys, { "esc", "back to the board" }) end
   table.insert(keys, { "⇧ P", "actions: mark all reviewed, open on GitHub and more" })
   if kind.hosted and kind.hosted.status then table.insert(keys, { "v", "reviewers and checks" }) end
   table.insert(keys, { "⇧ R", "generate LLM review" })
   table.insert(keys, { "⇧ M", "settings: AI models, effort and lens" })
   table.insert(keys, { "⇧ L", "review lens" })
   table.insert(keys, { "tab", "in that menu: explanation / review / lens" })
   table.insert(keys, { "⌃ E", "in that menu: edit lenses" })
  elseif group.title == "2  React" and kind.switch and not kind.guided then
   table.insert(keys, { "a  d", "add / dismiss suggestion" })
  end
  table.insert(out, { title = group.title, keys = keys })
 end
 return out
end

local M = {}

function M.view(closing: boolean, kind: Kind, enter: string): Node
 local cols = {}
 for _, group in groups(kind) do
  local rows = { span("gp-panel-h", group.title) }
  for _, key in group.keys do
   table.insert(rows, el("div", { class = "gp-keyrow" }, { Ui.keys(key[1]), span("gp-keylabel", key[2]) }))
  end
  table.insert(cols, el("div", { class = "gp-keycol" }, rows))
 end
 table.insert(cols, el("div", { class = "gp-keycol gp-keynote" }, {
  span("gp-panel-h", "Mouse"),
  span("gp-keylabel", "Hover a line and click + to comment. Click a second + to cover a range. Click a file name to fold it."),
 }))
 return el("div", { class = "gp-panel gp-keys " .. enter .. (if closing then " gp-closing-panel" else ""), key = "keys" }, cols)
end

return M
