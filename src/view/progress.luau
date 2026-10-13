--!strict
-- An AI run in progress, as the review page and the PR hub draw it: the turning spark, the phrase written in
-- once, an estimated progress bar and the clock.
local Agent = require("../agent")
local Ui = require("./ui")

local el = Ui.el

-- Steps the bar fill is drawn in; Tern nodes take no inline style, so each step is a class.
local BAR_STEPS = 50
-- Letters past this many write in together with the last one.
local STAGGERED_LETTERS = 30

local M = {}

-- `text` one letter per node, each writing in a little after the one before.
function M.writing(text: string): { Node }
 local letters = {}
 for i, code in utf8.codes(text) do
  local letter = if code == 32 then "\u{00A0}" else utf8.char(code)
  table.insert(letters, el("span", { class = "gp-ai-ch gp-ai-cd" .. math.min(#letters + 1, STAGGERED_LETTERS), key = "c" .. i, text = letter }))
 end
 return letters
end

-- The bar's fill class for a run `seconds` in that usually takes `expected`.
function M.step(seconds: number, expected: number): number
 return math.floor(Agent.progress(seconds, expected) * BAR_STEPS + 0.5)
end

function M.bar(seconds: number, expected: number, shine: boolean): Node
 local kids = { el("span", { class = "gp-ai-fill gp-pg" .. M.step(seconds, expected), key = "fill" }) }
 if shine then table.insert(kids, el("span", { class = "gp-ai-shine", key = "shine" })) end
 return el("span", { class = "gp-ai-bar", key = "bar" }, kids)
end

-- The whole row, a `tag` of `class`. The phrase is keyed by its text, so a new phrase writes in again.
function M.row(tag: string, class: string, key: string, phrase: string, seconds: number, expected: number): Node
 return el(tag, { class = class, key = key }, {
  el("span", { class = "gp-ai-spark", key = "spark" }, { Ui.icon("sparkle") }),
  el("span", { class = "gp-ai-phrase", key = "phrase:" .. phrase }, M.writing(phrase)),
  M.bar(seconds, expected, true),
  el("span", { class = "gp-ai-meta", key = "meta", text = Agent.clock(seconds) }),
 })
end

return M
