--!strict
-- The model and lens menu's state and what its actions do to the agent's picks, shared by the review
-- page's model menu and the PR hub's Settings. Effects (saving, closing, focusing) stay with each block.
local Agent = require("./agent")
local Fields = require("./text-field")
local Lens = require("./lens")

-- What the menu picks: a pass's model, or the review's lens.
export type Slot = Agent.Pass | "lens"

-- The menu: what it picks, its filter and the text the list was last filtered by, the highlighted
-- row (an index into `choices`, or `lensChoices` on the Lens slot), the effort the next pick gets,
-- and the first row its list shows.
export type ModelBox = { slot: Slot, field: Fields.Field, query: string, selected: number, effort: string?, top: number }

local M = {}

-- Rows the model list fits before it scrolls.
local MODEL_ROWS = 8

-- Whether `model` is the one `slot` uses.
function M.inUse(agent: Agent.Agent, slot: Agent.Pass, model: Agent.Model): boolean
 return model.selector == Agent.choiceFor(agent, slot).model
end

-- The models matching the filter.
function M.choices(box: ModelBox, agent: Agent.Agent): { Agent.Model }
 return Agent.matching(agent.models, box.field.text)
end

-- The lenses matching the filter.
function M.lensChoices(box: ModelBox, agent: Agent.Agent): { Lens.Lens }
 local needle = string.lower(box.field.text)
 if needle == "" then return agent.lenses end
 local found = {}
 for _, lens in agent.lenses do
  if string.find(string.lower(lens.name), needle, 1, true) then table.insert(found, lens) end
 end
 return found
end

-- The slot Tab goes to from `slot`.
function M.nextSlot(slot: Slot): Slot
 return if slot == "explain" then "review" elseif slot == "review" then "lens" else "explain"
end

-- The menu on `slot`, highlighting what that pass uses, or the lens in use.
function M.open(agent: Agent.Agent, slot: Slot): ModelBox
 if slot == "lens" then
  local box: ModelBox = { slot = slot, field = Fields.create(), query = "", selected = 1, top = 1 }
  for i, lens in agent.lenses do
   if lens.name == Agent.currentLens(agent).name then box.selected = i end
  end
  return box
 end
 local pass = slot :: Agent.Pass
 local box: ModelBox = { slot = slot, field = Fields.create(), query = "", selected = 1, effort = Agent.choiceFor(agent, pass).effort, top = 1 }
 for i, model in M.choices(box, agent) do
  if M.inUse(agent, pass, model) then box.selected = i end
 end
 box.top = math.max(1, box.selected - 3)
 return box
end

-- The lines the list draws from row `top` down to row `last`: each row, a provider heading where the
-- provider changes, and the "more" row above a list that starts lower down.
local function linesTo(choices: { Agent.Model }, top: number, last: number): number
 local lines, group = if top > 1 then 1 else 0, nil
 for n = top, last do
  local name = string.match(choices[n].selector, "^([^/]+)/") or ""
  if name ~= group then
   group = name
   lines += 1
  end
  lines += 1
 end
 return lines
end

-- Starts the list far enough down that the highlighted model is among the lines it fits, headings
-- included. The list is never scrolled to it: Tern's reveal into a scroller pins it, so the wheel
-- stops working.
local function keepShown(box: ModelBox, choices: { Agent.Model })
 if box.selected < box.top then
  box.top = box.selected
  return
 end
 while box.top < box.selected and linesTo(choices, box.top, box.selected) > MODEL_ROWS do
  box.top += 1
 end
end

function M.move(box: ModelBox, agent: Agent.Agent, delta: number)
 if box.slot == "lens" then
  box.selected = math.clamp(box.selected + delta, 1, math.max(1, #M.lensChoices(box, agent)))
  return
 end
 local choices = M.choices(box, agent)
 box.selected = math.clamp(box.selected + delta, 1, math.max(1, #choices))
 keepShown(box, choices)
end

-- Steps the effort the highlighted model will get through the levels it takes.
function M.stepEffort(box: ModelBox, agent: Agent.Agent, delta: number)
 if box.slot == "lens" then return end
 local model = M.choices(box, agent)[box.selected]
 if not model or #model.efforts == 0 then return end
 local at = table.find(model.efforts, Agent.effortFor(model, box.effort) :: string) :: number
 box.effort = model.efforts[(at - 1 + delta) % #model.efforts + 1]
end

-- Makes the highlighted model, with the effort it can take, the one the slot's pass runs with, or
-- the highlighted lens the review's; false when the filter matches nothing.
function M.choose(box: ModelBox, agent: Agent.Agent): boolean
 if box.slot == "lens" then
  local lens = M.lensChoices(box, agent)[box.selected]
  if lens then agent.lens = lens.name end
  return lens ~= nil
 end
 local model = M.choices(box, agent)[box.selected]
 if not model then return false end
 local effort = Agent.effortFor(model, box.effort)
 if box.slot == "review" then
  agent.model, agent.effort = model.selector, effort
 else
  agent.explain, agent.explainPicked = { model = model.selector, effort = effort }, true
 end
 box.effort = effort
 return true
end

-- What a menu action left behind: the box to show (a fresh one when the slot switched), whether the
-- agent's picks changed and want saving, and whether the menu closes.
export type Outcome = { box: ModelBox, save: boolean, close: boolean }

-- Runs the menu action `act` with `value` on `box`. A key steps or chooses; ⏎ (`models-pick`) chooses
-- and closes; a click on a row or an effort chooses it and leaves the menu open for the rest. Nil for
-- an action the menu doesn't know.
function M.act(box: ModelBox, agent: Agent.Agent, act: string, value: string): Outcome?
 local function stay(save: boolean): Outcome return { box = box, save = save, close = false } end
 if act == "models-slot" then
  if value == box.slot or (value ~= "explain" and value ~= "review" and value ~= "lens") then return stay(false) end
  return { box = M.open(agent, value :: Slot), save = false, close = false }
 elseif act == "models-filter" then
  if box.field.text ~= box.query then box.query, box.selected, box.top = box.field.text, 1, 1 end
  return stay(false)
 elseif act == "models-move" then
  M.move(box, agent, tonumber(value) :: number)
  return stay(false)
 elseif act == "models-top" then
  box.top = 1
  return stay(false)
 elseif act == "models-effort" then
  M.stepEffort(box, agent, tonumber(value) :: number)
  return stay(false)
 elseif act == "models-pick" then
  local chosen = M.choose(box, agent)
  return { box = box, save = chosen, close = chosen }
 elseif act == "model-row" then
  box.selected = tonumber(value) :: number
  return stay(M.choose(box, agent))
 elseif act == "model-effort" then
  box.effort = value
  return stay(M.choose(box, agent))
 end
 return nil
end

return M
