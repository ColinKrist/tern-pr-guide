--!strict
-- The PR in plain words, then one run through the code before and after it, with the changed parts marked.
local Guide = require("../guide")
local Review = require("../review")
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local SIGNS: { [Guide.Tone]: string } = { added = "+", removed = "−", changed = "~" }
local LEGEND: { Guide.Tone } = { "added", "changed", "removed" }
local NAMES: { [Guide.Tone]: string } = { added = "Added", changed = "Changed", removed = "Removed" }
-- Estimated height of the open diagram, for its unroll animation.
local FLOW_H = 240

local M = {}

-- A name that isn't code (it has a space) is set in the UI font.
local function name(text: string): Node
 return span(if string.find(text, " ") then "gp-fb-name gp-fb-prose" else "gp-fb-name", text)
end

-- One box. `tone` marks the side that carries the change; `go` is the step a click opens.
local function box(text: string, tone: Guide.Tone?, note: string?, change: number?, go: number?): Node
 local top = {}
 if tone then table.insert(top, span("gp-fb-sign", SIGNS[tone])) end
 table.insert(top, name(text))
 local kids = { el("div", { class = "gp-fb-top" }, top) }
 if note or go then
  local row = {}
  if note then table.insert(row, span("gp-fb-note-text", note)) end
  if go then table.insert(row, span("gp-fb-go", "Change " .. tostring(change) .. " ›")) end
  table.insert(kids, el("div", { class = "gp-fb-note" }, row))
 end
 return el("div", {
  class = "gp-fb gp-fb-" .. (tone or "plain") .. (if go then " gp-fb-link" else ""),
  actions = if go then { click = "goto-step=" .. go } else nil,
 }, kids)
end

-- One lane of a touched stage: its boxes, or a muted word where that side has nothing.
local function cell(names: { string }, empty: string, tone: Guide.Tone?, note: string?, change: number?, go: number?): Node
 if #names == 0 then return el("div", { class = "gp-fc gp-fc-none" }, { span("gp-fc-empty", empty) }) end
 local kids = {}
 for _, text in names do
  table.insert(kids, box(text, tone, if #names == 1 then note else nil, change, if #names == 1 then go else nil))
 end
 return el("div", { class = "gp-fc" }, kids)
end

local function stage(r: Review.Review, st: Guide.Stage, n: number, flagged: boolean): Node
 local head = { span("gp-fl-h-text", st.label) }
 if flagged then table.insert(head, 1, Ui.icon("warn")) end
 local kids = { el("div", { class = "gp-fl-h" .. (if flagged then " gp-fl-flag" else "") }, head) }
 if not st.tone then
  -- Unchanged: one box across both lanes.
  -- Two names here are alternatives, so they share the box rather than sitting on the two rows.
  local names = if #st.after > 0 then st.after else st.before
  local top = { name(names[1]) }
  if names[2] then table.insert(top, span("gp-fb-or", "or")); table.insert(top, name(names[2])) end
  local inner = { el("div", { class = "gp-fb-top gp-fb-alts" }, top) }
  if st.note then table.insert(inner, el("div", { class = "gp-fb-note" }, { span("gp-fb-note-text", st.note) })) end
  table.insert(kids, el("div", { class = "gp-fc gp-fc-span" }, { el("div", { class = "gp-fb gp-fb-plain" }, inner) }))
 else
  local go = if st.change then Review.firstStep(r, st.change) else nil
  local removed = st.tone == "removed"
  table.insert(kids, cell(st.before, "Didn't exist", if removed then "removed" else nil, st.beforeNote, st.change, if removed then go else nil))
  table.insert(kids, el("div", { class = "gp-fl-gap" }))
  table.insert(kids, cell(st.after, "Removed", if removed then nil else st.tone, st.note, st.change, if removed then nil else go))
 end
 return el("div", { class = "gp-fs" .. (if st.tone then "" else " gp-fs-same"), key = "s" .. n }, kids)
end

local function arrows(on: boolean): Node
 if not on then return el("div", { class = "gp-fa gp-fa-off" }) end
 return el("div", { class = "gp-fa" }, {
  el("div", { class = "gp-fl-h" }), span("gp-fa-c", "→"), el("div", { class = "gp-fl-gap" }), span("gp-fa-c", "→"),
 })
end

local function flow(s: State.State, motion: Ui.Motion, diagram: Guide.Flow): Node
 local present: { [string]: boolean } = {}
 for _, st in diagram.stages do if st.tone then present[st.tone] = true end end
 local legend = {}
 for _, tone in LEGEND do
  if present[tone] then
   table.insert(legend, el("span", { class = "gp-flow-key gp-flow-key-" .. tone }, { span("gp-fb-sign", SIGNS[tone]), span("gp-flow-key-text", NAMES[tone]) }))
  end
 end
 local kids = { el("div", { class = "gp-flow-head", key = "head", actions = { click = "toggle-flow" } }, {
  Ui.caret(s.flowOpen),
  span("gp-flow-title", diagram.title),
  Ui.spacer(),
  el("div", { class = "gp-flow-legend" }, legend),
 }) }
 if s.flowOpen or s.closing.flow then
  local lanes = { el("div", { class = "gp-fl-gutter" }, {
   el("div", { class = "gp-fl-h" }), span("gp-fl-lane", "Before"), el("div", { class = "gp-fl-gap" }), span("gp-fl-lane", "After"),
  }) }
  for n, st in diagram.stages do
   if n > 1 then table.insert(lanes, arrows(diagram.arrows)) end
   table.insert(lanes, stage(s.review, st, n, diagram.checkStage == n))
  end
  local body = { el("div", { class = "gp-hscroll" }, { el("div", { class = "gp-fl-lanes" }, lanes) }) }
  if diagram.check then
   table.insert(body, el("div", { class = "gp-flow-check" }, { span("gp-flow-check-k", "Check"), el("div", { class = "gp-flow-check-t" }, { Ui.rich(diagram.check) }) }))
  end
  table.insert(kids, Ui.body(motion, "flow", s.closing.flow == true, FLOW_H, body))
 end
 return el("div", { class = "gp-flow", key = "flow" }, kids)
end

-- Nil when the guide has neither a TL;DR nor a diagram.
function M.view(s: State.State, motion: Ui.Motion): Node?
 local guide = s.review.guide
 if guide.overview == "" and not guide.flow then return nil end
 local kids = {}
 if guide.overview ~= "" then
  table.insert(kids, el("div", { class = "gp-ov-text" }, {
   span("gp-ov-h", "Overview"),
   el("div", { class = "gp-ov-summary" }, { Ui.rich(guide.overview) }),
  }))
 end
 if guide.flow then table.insert(kids, flow(s, motion, guide.flow)) end
 return el("div", { class = "gp-overview", key = "overview" }, kids)
end

return M
