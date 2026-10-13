--!strict
-- The model and lens menu: an Explanation | Review | Lens switch with a hint for the slot shown, a
-- filter, and the slot's models matching it grouped by provider with the efforts the highlighted model
-- takes as one segmented control, or on Lens the lenses with their descriptions. The review page shows
-- it as Tern's overlay under its Settings button; the PR hub's Settings puts it in its own overlay.
local Agent = require("../agent")
local ModelBox = require("../model-box")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local SLOTS: { { id: ModelBox.Slot, label: string, hint: string } } = {
 { id = "explain", label = "Explanation", hint = "Explains what the PR changes, step by step. A fast model at low effort is enough." },
 { id = "review", label = "Review", hint = "Drafts comments on problems and questions. Use a strong model; higher effort finds more." },
 { id = "lens", label = "Lens", hint = "What the review comments pay attention to." },
}

local M = {}

local function provider(model: Agent.Model): string
 return string.match(model.selector, "^([^/]+)/") or ""
end

-- The slot switch, its key, and what the slot shown is for.
local function slots(box: ModelBox.ModelBox): Node
 local segments, hint = {}, ""
 for _, slot in SLOTS do
  if slot.id == box.slot then hint = slot.hint end
  table.insert(segments, el("span", {
   class = "gp-md-seg" .. (if slot.id == box.slot then " gp-md-seg-on" else ""),
   key = slot.id,
   text = slot.label,
   actions = { click = "models-slot=" .. slot.id },
  }))
 end
 return el("div", { class = "gp-md-slots", key = "slots" }, {
  el("div", { class = "gp-md-slots-row", key = "switch" }, {
   el("div", { class = "gp-md-segs", key = "segs" }, segments),
   Ui.spacer(),
   Ui.keys("tab"),
  }),
  span("gp-md-hint", hint),
 })
end

-- The effort control for `model`; nil when nothing matches the filter, which the list already says.
local function efforts(box: ModelBox.ModelBox, model: Agent.Model?): Node?
 if not model then return nil end
 if #model.efforts == 0 then
  return el("div", { class = "gp-md-foot", key = "efforts" }, { span("gp-md-none", "This model has no effort setting") })
 end
 local current = Agent.effortFor(model, box.effort)
 local segments = {}
 for _, effort in model.efforts do
  table.insert(segments, el("span", {
   class = "gp-md-seg" .. (if effort == current then " gp-md-seg-on" else ""),
   text = effort,
   actions = { click = "model-effort=" .. effort },
  }))
 end
 return el("div", { class = "gp-md-foot", key = "efforts" }, {
  span("gp-md-label", "Effort"),
  el("div", { class = "gp-md-segs" }, segments),
  Ui.spacer(),
  Ui.keys("← →"),
 })
end

-- The Lens slot's list: each lens matching the filter with its description, a check on the one in
-- use, and under them the way to the folder of the reader's own lenses.
local function lenses(box: ModelBox.ModelBox, agent: Agent.Agent): { Node }
 local current = Agent.currentLens(agent).name
 local rows = {}
 for n, lens in ModelBox.lensChoices(box, agent) do
  local check = el("span", { class = "gp-md-check" }, if lens.name == current then { Ui.icon("check") } else nil)
  table.insert(rows, el("div", { class = "gp-md-row gp-md-lens-item" .. (if n == box.selected then " gp-md-row-on" else ""), key = "l" .. n, actions = { click = "model-row=" .. n } }, {
   el("div", { class = "gp-md-lens-text" }, { span("gp-md-name", lens.name), span("gp-md-lens-desc", lens.description) }),
   check,
  }))
 end
 if #rows == 0 then table.insert(rows, span("gp-md-empty", "Nothing matches “" .. box.field.text .. "”")) end
 return {
  el("div", { class = "gp-md-list", key = "lenslist" }, rows),
  el("div", { class = "gp-md-foot", key = "lenses" }, {
   Ui.spacer(),
   el("span", { class = "gp-md-edit", key = "edit", actions = { click = "edit-lenses" } }, {
    span("gp-md-edit-label", "Edit lenses…"),
    Ui.keys("⌃E"),
   }),
  }),
 }
end

local function search(box: ModelBox.ModelBox): Node
 return el("div", { class = "gp-md-search", key = "box" }, { Ui.icon("search"), Ui.field(box.field, "field", if box.slot == "lens" then "Search lenses" else "Search models") })
end

-- The menu's parts, top to bottom, keyed "slots", "box" (its field "field"), the list, and "efforts",
-- or on Lens "lenslist" and "lenses". The model list starts at row `box.top`, under a row offering the
-- ones above it. Its key changes with `top` and the slot, so the list draws as a fresh scroller at its
-- own start and the wheel scrolls it freely.
function M.parts(box: ModelBox.ModelBox, agent: Agent.Agent): { Node }
 if box.slot == "lens" then
  local kids = { slots(box), search(box) }
  for _, node in lenses(box, agent) do table.insert(kids, node) end
  return kids
 end
 local pass = box.slot :: Agent.Pass
 local choices = ModelBox.choices(box, agent)
 local rows, group = {}, nil
 if box.top > 1 then
  table.insert(rows, el("div", { class = "gp-md-more", key = "above", text = "↑  " .. (box.top - 1) .. " more", actions = { click = "models-top" } }))
 end
 for n = box.top, #choices do
  local model = choices[n]
  local name = provider(model)
  if name ~= group then
   group = name
   table.insert(rows, el("div", { class = "gp-md-group", key = "g-" .. name, text = name }))
  end
  local check = el("span", { class = "gp-md-check" }, if ModelBox.inUse(agent, pass, model) then { Ui.icon("check") } else nil)
  table.insert(rows, el("div", { class = "gp-md-row" .. (if n == box.selected then " gp-md-row-on" else ""), key = "m" .. n, actions = { click = "model-row=" .. n } }, {
   span("gp-md-name", model.name), Ui.spacer(), check,
  }))
 end
 if #agent.models == 0 then
  table.insert(rows, span("gp-md-empty", "Listing models…"))
 elseif #choices == 0 then
  table.insert(rows, span("gp-md-empty", "Nothing matches “" .. box.field.text .. "”"))
 end
 local kids = {
  slots(box),
  search(box),
  el("div", { class = "gp-md-list", key = box.slot .. "list" .. box.top }, rows),
 }
 local foot = efforts(box, choices[box.selected])
 if foot then table.insert(kids, foot) end
 return kids
end

-- The review page's menu. `anchor` is the full node id of the button the card opens under. The rows
-- fade between states only under `soft`, as on the page: a key never animates.
function M.view(box: ModelBox.ModelBox, agent: Agent.Agent, anchor: string, soft: boolean): Node
 local body = el("div", { class = "gp-md" .. (if soft then " gp-soft" else ""), key = "body" }, M.parts(box, agent))
 return { k = "overlay", p = { key = "models", role = "gp.models", aria = "Models, effort and lens", anchor = { node = anchor, side = "below" }, size = "md" }, c = { body } } :: any
end

return M
