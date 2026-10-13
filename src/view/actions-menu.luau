--!strict
-- The review page's Actions menu: what to do with the PR, its rows in groups set off by a hairline, each with its key, as
-- a Tern overlay under the header's Actions button.
local State = require("../state")
local Ui = require("./ui")

local el, span = Ui.el, Ui.span

local M = {}

-- `soft`: opened by the mouse, so the overlay pops in and rows ease; a key opens it still.
function M.view(rows: { State.ActionRow }, cursor: number, anchor: string, soft: boolean): Node
 local kids: { Node } = {}
 for index, row in rows do
  if index > 1 and rows[index - 1].group ~= row.group then table.insert(kids, el("div", { class = "gp-am-div", key = "d" .. index })) end
  table.insert(kids, el("div", {
   class = "gp-md-row gp-hm-row" .. (if index == cursor then " gp-md-row-on" else "") .. (if row.group == "close" then " gp-am-danger" else ""),
   key = "r" .. index, actions = { click = "actions-run=" .. index },
  }, { span("gp-hm-label", row.label), Ui.spacer(), Ui.keys(row.key) }))
 end
 local body = el("div", { class = "gp-md gp-hm" .. (if soft then " gp-soft" else ""), key = "body" }, {
  el("div", { class = "gp-md-list gp-hm-list", key = "list" }, kids),
 })
 return { k = "overlay", p = { key = "actions", role = "gp.actions", aria = "Actions", anchor = { node = anchor, side = "below" }, size = "md" }, c = { body } } :: any
end

return M
