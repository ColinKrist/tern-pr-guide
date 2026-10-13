--!strict
local Moves = require("./moves")
local Pr = require("./pr")
local Text = require("./text")

-- Byte positions in a line: `from` is the first, `to` the one after the last.
export type Span = { from: number, to: number }
-- Entry numbers, both included.
export type Interval = { first: number, last: number }
export type Move = Moves.Move

-- One line of the new-side file. Lines the PR's diff lists carry `diff = true`, the word-diff span
-- of a paired removed/added line, and the hunk label when they open a hunk. Unchanged lines
-- between hunks are filled in from the file source. A line that was cut and pasted elsewhere in
-- the PR carries `moved`, and no word-diff span.
export type Entry = {
 row: Pr.Line,
 diff: boolean,
 changed: Span?,
 label: string?,
 -- The new-side line the entry sits at; a removed line belongs with the line after it.
 anchor: number?,
 -- Where the other half of a moved line is.
 moved: Move?,
}

export type Token = { text: string, kind: string, changed: boolean }

-- How one language's lines are colored: its keywords, the markers that comment out the rest of a
-- line, a block comment's open and close, and the characters that open a string. `caseless`
-- matches keywords in any case.
export type Syntax = {
 keywords: { [string]: boolean },
 comments: { string },
 block: { string }?,
 quotes: string,
 caseless: boolean?,
}

export type Rows = { kind: "rows", first: number, last: number }
-- A run of unchanged lines of a big file, left to Tern's own code viewer.
export type Native = { kind: "native", first: number, last: number }
-- A run of hidden unchanged lines; `reveal` is what a click opens.
export type Gap = {
 kind: "gap", first: number, last: number,
 hidden: number, reveal: Interval, arrow: string, label: string?,
}
export type Segment = Rows | Native | Gap

-- A code block as segments in file order, with the number of lines it draws as rows; `key` is
-- what it was laid out for.
export type Layout = { key: string, segments: { Segment }, rows: number }

export type FileDiff = {
 file: Pr.File,
 entries: { Entry },
 -- How to color its lines; nil draws them plain.
 syntax: Syntax?,
 -- The language name Tern's own code viewer gets.
 language: string,
 -- Joined text of native runs, by "first-last".
 runs: { [string]: string },
 -- Colored pieces of each entry, by entry number, filled in as lines are first drawn.
 tokens: { [number]: { Token } },
 -- The last layout of each block on the file, by the lines it is based on.
 layouts: { [string]: Layout },
}

-- What a code block shows of a file.
export type Show = {
 -- The entries of the steps the block shows (see `stepSpan`); it starts with the PR's lines within
 -- a couple of lines of them, and at the line that opens the scope around each (see `scopeOf`).
 -- Nil starts with every line of the PR's diff.
 spans: { Interval }?,
 -- The whole file was asked for.
 whole: boolean,
 -- New-side lines with cards hung under them.
 annotated: { [number]: boolean },
 -- The entry a search jumped to.
 hit: number?,
 -- Ranges the reader opened.
 reveals: { Interval },
}

local function wordSet(list: string): { [string]: boolean }
 local set = {}
 for word in string.gmatch(list, "%S+") do set[word] = true end
 return set
end

local C_BLOCK = { "/*", "*/" }

local JS: Syntax = {
 keywords = wordSet("const let var function return if else for while do switch case default break continue of in new delete void await async yield export import from type interface enum class extends implements this super null undefined true false throw try catch finally typeof instanceof as readonly static public private protected"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"'`",
}
local PYTHON: Syntax = {
 keywords = wordSet("def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield global nonlocal assert del async await None True False self"),
 comments = { "#" }, quotes = "\"'",
}
local GO: Syntax = {
 keywords = wordSet("package import func return if else for range switch case default break continue go defer select chan map struct interface type var const fallthrough goto nil true false"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"'`",
}
-- `'` also opens a lifetime (`'a`), so only `"` opens a string.
local RUST: Syntax = {
 keywords = wordSet("fn let mut const static return if else match for while loop in break continue struct enum trait impl pub use mod crate self super where as ref move async await dyn unsafe extern type true false"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"",
}
local RUBY: Syntax = {
 keywords = wordSet("def end class module return if elsif else unless case when while until for in do begin rescue ensure raise yield self nil true false and or not then require"),
 comments = { "#" }, quotes = "\"'",
}
local JAVA: Syntax = {
 keywords = wordSet("class interface enum extends implements package import public private protected static final abstract void return if else for while do switch case default break continue new this super null true false throw throws try catch finally instanceof var record"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"'",
}
local KOTLIN: Syntax = {
 keywords = wordSet("fun val var class object interface data sealed enum open override private public internal protected return if else when for while do in is as break continue null true false this super throw try catch finally import package companion suspend"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"'",
}
local SWIFT: Syntax = {
 keywords = wordSet("func let var class struct enum protocol extension import return if else guard switch case default for in while repeat break continue nil true false self throw throws try catch do async await public private internal fileprivate static override init deinit some any"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"",
}
local C: Syntax = {
 keywords = wordSet("int char float double long short unsigned signed void bool auto const static extern struct union enum typedef return if else for while do switch case default break continue goto sizeof class namespace template typename public private protected virtual override new delete this nullptr true false using include define ifdef ifndef endif"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"'",
}
local CSHARP: Syntax = {
 keywords = wordSet("class interface struct enum namespace using public private protected internal static readonly const void var return if else for foreach in while do switch case default break continue new this base null true false throw try catch finally async await override virtual abstract sealed record get set"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"'",
}
local SHELL: Syntax = {
 keywords = wordSet("if then else elif fi for in do done while until case esac function return local export set unset echo exit source"),
 comments = { "#" }, quotes = "\"'",
}
local LUA: Syntax = {
 keywords = wordSet("local function return if then elseif else end for in do while repeat until break continue not and or nil true false type export"),
 comments = { "--" }, quotes = "\"'`",
}
local CSS: Syntax = {
 keywords = wordSet("important media import supports keyframes"),
 comments = { "//" }, block = C_BLOCK, quotes = "\"'",
}
local JSON: Syntax = { keywords = wordSet("true false null"), comments = {}, quotes = "\"" }
local YAML: Syntax = { keywords = wordSet("true false null yes no"), comments = { "#" }, quotes = "\"'" }
local TOML: Syntax = { keywords = wordSet("true false"), comments = { "#" }, quotes = "\"'" }
local SQL: Syntax = {
 keywords = wordSet("select from where and or not insert into values update set delete create table alter drop index join left right inner outer on as group by order having limit offset null is in like between case when then else end primary key references default distinct union all"),
 comments = { "--" }, block = C_BLOCK, quotes = "\"'", caseless = true,
}

-- What each file extension is colored as, and the name Tern's own code viewer knows it by (the
-- extension when unset). A new language is one entry here.
local EXTENSIONS: { [string]: { syntax: Syntax?, language: string? } } = {
 ts = { syntax = JS }, tsx = { syntax = JS }, js = { syntax = JS }, jsx = { syntax = JS },
 mjs = { syntax = JS, language = "js" }, cjs = { syntax = JS, language = "js" },
 py = { syntax = PYTHON }, go = { syntax = GO }, rs = { syntax = RUST }, rb = { syntax = RUBY },
 java = { syntax = JAVA }, kt = { syntax = KOTLIN }, kts = { syntax = KOTLIN }, swift = { syntax = SWIFT },
 c = { syntax = C }, h = { syntax = C }, cc = { syntax = C }, cpp = { syntax = C }, hpp = { syntax = C },
 cs = { syntax = CSHARP },
 sh = { syntax = SHELL }, bash = { syntax = SHELL }, zsh = { syntax = SHELL },
 lua = { syntax = LUA }, luau = { syntax = LUA, language = "lua" },
 css = { syntax = CSS }, scss = { syntax = CSS },
 json = { syntax = JSON }, yaml = { syntax = YAML }, yml = { syntax = YAML }, toml = { syntax = TOML },
 sql = { syntax = SQL },
 md = { language = "markdown" },
}

-- Entries a step shows on each side of its range.
local STEP_CONTEXT = 2
-- How many entries above a step's range its block reaches for the line that opens the enclosing scope.
local SCOPE_REACH = 30
-- The longest scope opener shown as the label of a gap, in bytes.
local SCOPE_LABEL = 80
-- Unchanged lines that stay as rows on each side of a change when a big file is shown whole.
local NEAR = 3
-- A file shown whole with more lines than this draws its unchanged stretches natively.
local WHOLE_MAX = 800
-- Lines one click on a gap opens.
local EXPAND_STEP = 20

local M = {}

-- Changed middle of a paired removed/added line: the span on each side.
local function changedMiddle(old: string, new: string): (Span, Span)
 local prefix = 0
 while prefix < #old and prefix < #new and string.byte(old, prefix + 1) == string.byte(new, prefix + 1) do prefix += 1 end
 local suffix = 0
 while suffix < #old - prefix and suffix < #new - prefix and string.byte(old, #old - suffix) == string.byte(new, #new - suffix) do suffix += 1 end
 return { from = prefix + 1, to = #old - suffix + 1 }, { from = prefix + 1, to = #new - suffix + 1 }
end

local function rowText(row: Pr.Row): string
 return if row.kind == "hunk" then "" else row.text
end

local function trimmed(span: Span, text: string): Span
 local first = string.find(text, "%S") or (#text + 1)
 local last = #text
 while last > 0 and string.match(string.sub(text, last, last), "%s") do last -= 1 end
 return { from = math.max(span.from, first), to = math.min(span.to, last + 1) }
end

-- Pairs each run of removed lines with the added lines after it: row index -> changed span. Moved
-- lines pair with nothing.
local function pairChanges(rows: { Pr.Row }, moves: { [number]: Move }): { [number]: Span }
 local spans: { [number]: Span } = {}
 local i = 1
 while i <= #rows do
  if rows[i].kind == "del" and not moves[i] then
   local firstDel = i
   while i <= #rows and rows[i].kind == "del" and not moves[i] do i += 1 end
   local firstAdd = i
   while i <= #rows and rows[i].kind == "add" and not moves[i] do i += 1 end
   local dels, adds = firstAdd - firstDel, i - firstAdd
   for k = 0, math.min(dels, adds) - 1 do
    spans[firstDel + k], spans[firstAdd + k] = changedMiddle(rowText(rows[firstDel + k]), rowText(rows[firstAdd + k]))
   end
   if dels > 0 and adds > 0 and dels ~= adds then
    -- Several removed lines collapsed into one added line (or the reverse): compare the joined removed text.
    local firstText = rowText(rows[firstDel])
    local joined = ""
    for k = 0, dels - 1 do
     joined ..= (if k == 0 then "" else " ") .. string.gsub(rowText(rows[firstDel + k]), "^%s+", "")
    end
    joined = (string.match(firstText, "^%s*") :: string) .. joined
    local _, addedSpan = changedMiddle(joined, rowText(rows[firstAdd]))
    spans[firstAdd] = addedSpan
    for k = 1, dels - 1 do spans[firstDel + k] = { from = 1, to = #rowText(rows[firstDel + k]) + 1 } end
    spans[firstDel] = (changedMiddle(firstText, rowText(rows[firstAdd])))
   end
  else
   i += 1
  end
 end
 for index, span in spans do spans[index] = trimmed(span, rowText(rows[index])) end
 return spans
end

local function buildEntries(file: Pr.File, spans: { [number]: Span }, moves: { [number]: Move }): { Entry }
 local entries: { Entry } = {}
 local src = file.src or {}
 local newN, oldN, label = 1, 1, nil
 local function fillUnchanged(untilNew: number)
  while newN < untilNew and newN <= #src do
   local row: Pr.Line = { kind = "ctx", old = oldN, new = newN, text = src[newN] }
   table.insert(entries, { row = row, diff = false })
   newN += 1
   oldN += 1
  end
 end
 for index, row in file.rows do
  if row.kind == "hunk" then
   fillUnchanged(row.newStart)
   newN, oldN, label = row.newStart, row.oldStart, row.label
  else
   table.insert(entries, { row = row, diff = true, changed = spans[index], label = label, moved = moves[index] })
   label = nil
   if row.new then newN = row.new + 1 end
   if row.old then oldN = row.old + 1 end
  end
 end
 fillUnchanged(#src + 1)
 return entries
end

local function anchorEntries(entries: { Entry })
 local following: number? = nil
 for i = #entries, 1, -1 do
  local line = entries[i].row.new
  following = line or following
  entries[i].anchor = following
 end
 local preceding: number? = nil
 for _, entry in entries do
  preceding = entry.row.new or preceding
  entry.anchor = entry.anchor or preceding
 end
end

-- Whether a block starts with entry `i`: a line of the PR's diff, and for a block of steps within a
-- couple of entries of one of their `spans`.
local function inBase(entries: { Entry }, i: number, spans: { Interval }?): boolean
 if not entries[i].diff then return false end
 if spans == nil then return true end
 for _, span in spans do
  if i >= span.first - STEP_CONTEXT and i <= span.last + STEP_CONTEXT then return true end
 end
 return false
end

-- What opens a scope, language-agnostic: the line ends with an opening bracket, `:`, `=>`, `->`,
-- `then`, `do` or `begin`, or it declares something (starts with function, def, fn, func, fun,
-- class, struct, enum, trait, impl, interface, module, namespace or object, after modifiers like
-- export or async, mentions `function`, or looks like a method, `name(…) {`, unless `name` is a
-- control keyword such as `if`).
local OPENING_ENDS = { "{", "(", "[", ":", "=>", "->" }
local OPENING_WORDS: { [string]: boolean } = { ["then"] = true, ["do"] = true, ["begin"] = true }
local MODIFIERS: { [string]: boolean } = {}
for word in string.gmatch("export default async public private protected static pub abstract final override local unsafe extern inline virtual readonly", "%S+") do MODIFIERS[word] = true end
local DECLARATORS: { [string]: boolean } = {}
for word in string.gmatch("function def fn func fun class struct enum trait impl interface module namespace object", "%S+") do DECLARATORS[word] = true end
-- Lines that continue the scope above them (`end`, `else`, `} else {`) are never its opener.
local CONTINUATIONS: { [string]: boolean } = {}
for word in string.gmatch("end else elseif elif except catch finally", "%S+") do CONTINUATIONS[word] = true end
local CONTROL: { [string]: boolean } = {}
for word in string.gmatch("if for while switch catch elseif elif return await yield try do with when match", "%S+") do CONTROL[word] = true end

-- A line's text without indentation and a trailing `//` or `--` comment.
local function stripped(text: string): string
 local code = (string.gsub(text, "(%S)%s+//.*$", "%1"))
 code = string.gsub(code, "(%S)%s+%-%-.*$", "%1")
 code = string.gsub(code, "^%s+", "")
 return (string.gsub(code, "%s+$", ""))
end

-- Whether the line starts by closing something: `}`, `)`, `]`, `</`, or `end`/`else`/`catch` and kin.
local function closes(code: string): boolean
 if string.find(code, "^[})%]]") or string.sub(code, 1, 2) == "</" then return true end
 return CONTINUATIONS[string.match(code, "^[%a_]+") or ""] == true
end

-- Whether the line declares a function, class, method or the like.
local function declares(code: string): boolean
 if string.find(code, "%f[%w_]function%f[^%w_]") then return true end
 for word in string.gmatch(code, "[%a_]+") do
  if DECLARATORS[word] then return true end
  if not MODIFIERS[word] then break end
 end
 local rest = code
 while true do
  local word, after = string.match(rest, "^([%a_]+)%s+(.*)$")
  if word and after and MODIFIERS[word] then rest = after else break end
 end
 local name = string.match(rest, "^([%a_$][%w_$]*)%s*[%(<]")
 return name ~= nil and not CONTROL[name] and string.sub(code, -1) == "{"
end

local function opensScope(code: string): boolean
 if code == "" or closes(code) then return false end
 if declares(code) then return true end
 for _, ending in OPENING_ENDS do
  if string.sub(code, -#ending) == ending then return true end
 end
 return OPENING_WORDS[string.match(code, "([%a_]+)$") or ""] == true
end

local function indentOf(text: string): number
 return #(string.match(text, "^[ \t]*") :: string)
end

-- The entry that opens the scope enclosing a step's `span`, so a block can start there like an
-- editor's sticky scroll. Walks up the new-side lines (removed lines are skipped, except in a deleted
-- file where they are all there is) from the span's first entry through the lines indented less
-- than the span's first line of code, each less than the one before it, and stops at the first
-- that declares a function, class or method; the `if` and `for` blocks between are passed over.
-- Where none declares (a stylesheet, a data file), it is the outermost line that opens a scope.
-- A less indented line that opens nothing narrows the walk the same way: nothing above it can
-- enclose the span unless it is less indented still. Lines that start by closing something
-- (`}`, `) {`, `end`) never count. A span that starts by declaring something, or holds only
-- blank lines, has no scope to show; a span of only closing lines is enclosed by the line at its
-- own indentation. The walk stops at a gap between hunks when the file has no source. Nil when no
-- line encloses the span.
local function scopeOf(fd: FileDiff, span: Interval): number?
 local entries = fd.entries
 local skipRemoved = fd.file.src ~= nil
 local bar: number? = nil
 local closing: number? = nil
 for i = span.first, span.last do
  local row = entries[i].row
  local code = stripped(row.text)
  if code ~= "" then
   if closes(code) then
    closing = closing or indentOf(row.text) + 1
   else
    if declares(code) then return nil end
    bar = indentOf(row.text)
    break
   end
  end
 end
 bar = bar or closing
 if bar == nil then return nil end
 local outermost: number? = nil
 local below: number? = entries[span.first].row.new
 for i = span.first - 1, 1, -1 do
  if bar == 0 then break end
  local row = entries[i].row
  if row.kind == "del" and skipRemoved then continue end
  if row.new then
   if below and row.new < below - 1 then break end
   below = row.new
  end
  local code = stripped(row.text)
  if code == "" then continue end
  local indent = indentOf(row.text)
  if indent >= bar then continue end
  if closes(code) then continue end
  bar = indent
  local at, allman = i, false
  if code == "{" then
   -- Allman braces: the line before a lone `{` is what opens the scope, and a declaration unless it
   -- is a control line like `if (a)`.
   for k = i - 1, 1, -1 do
    local before = stripped(entries[k].row.text)
    if before ~= "" and not (skipRemoved and entries[k].row.kind == "del") then
     at, code, allman = k, before, not closes(before) and not CONTROL[string.match(before, "^[%a_]+") or ""]
     break
    end
   end
  end
  if allman or declares(code) then return at end
  if opensScope(code) then outermost = at end
 end
 return outermost
end

-- Rows of the entries to draw: every shown entry, and for a big file shown whole only those near
-- changes, comments and the search hit. A block of steps also starts at the line that opens the
-- scope enclosing each step when that is within `SCOPE_REACH` entries; when it is farther, the
-- opener's text is returned under the entry the block starts at, to label the gap above it.
local function shownEntries(fd: FileDiff, show: Show): ({ boolean }, boolean, { [number]: string })
 local entries = fd.entries
 local total = #entries
 local big = show.whole and total > WHOLE_MAX
 local shown = table.create(total, false)
 local openers: { [number]: string } = {}
 for i = 1, total do shown[i] = (show.whole and not big) or inBase(entries, i, show.spans) end
 if show.spans and not show.whole then
  for _, span in show.spans do
   local opener = scopeOf(fd, span)
   if opener and span.first - opener <= SCOPE_REACH then
    for i = opener, span.first - 1 do shown[i] = true end
   elseif opener then
    for i = math.max(span.first - STEP_CONTEXT, 1), span.first do
     if entries[i].diff then
      local text = stripped(entries[opener].row.text)
      openers[i] = if #text > SCOPE_LABEL then string.sub(text, 1, SCOPE_LABEL) .. "…" else text
      break
     end
    end
   end
  end
 end
 if big then
  for i, entry in entries do
   if entry.diff then
    for j = math.max(i - NEAR, 1), math.min(i + NEAR, total) do shown[j] = true end
   elseif entry.row.new and show.annotated[entry.row.new] then
    shown[i] = true
   end
  end
  if show.hit and entries[show.hit] then shown[show.hit] = true end
 end
 for _, range in show.reveals do
  for i = math.max(range.first, 1), math.min(range.last, total) do shown[i] = true end
 end
 return shown, big, openers
end

-- A click opens the lines nearest the code (all of them when few are left); the arrow says which
-- way the gap grows.
local function gapAt(first: number, last: number, total: number, label: string?): Gap
 local hidden = last - first + 1
 local from, to, arrow = first, math.min(last, first + EXPAND_STEP - 1), "↓"
 if first == 1 then
  from, to, arrow = math.max(first, last - EXPAND_STEP + 1), last, "↑"
 elseif last < total then
  arrow = "↕"
 end
 if hidden <= EXPAND_STEP + 10 then from, to = first, last end
 return { kind = "gap", first = first, last = last, hidden = hidden, reveal = { first = from, last = to }, arrow = arrow, label = label }
end

local function startsAt(line: string, i: number, marker: string): boolean
 return string.sub(line, i, i + #marker - 1) == marker
end

-- Splits a line into colored pieces, each `{ text, kind }`.
-- ponytail: a block comment or string that spans lines colors only the line it opens on, since
-- lines are tokenized one at a time.
local function tokenize(line: string, syntax: Syntax): { { string } }
 local tokens, i, n = {}, 1, #line
 local function take(last: number, kind: string)
  table.insert(tokens, { string.sub(line, i, last), kind })
  i = last + 1
 end
 while i <= n do
  local c = string.sub(line, i, i)
  local _, last = string.find(line, "^%s+", i)
  if last then take(last, "plain"); continue end
  local comment = false
  for _, marker in syntax.comments do comment = comment or startsAt(line, i, marker) end
  if comment then take(n, "com"); break end
  local block = syntax.block
  if block and startsAt(line, i, block[1]) then
   local _, close = string.find(line, block[2], i + #block[1], true)
   take(close or n, "com")
   continue
  end
  if string.find(syntax.quotes, c, 1, true) then
   local j = i + 1
   while j <= n and string.sub(line, j, j) ~= c do
    if string.sub(line, j, j) == "\\" then j += 1 end
    j += 1
   end
   take(math.min(j, n), "str")
   continue
  end
  _, last = string.find(line, "^[%a_$][%w_$]*", i)
  if last then
   local word = string.sub(line, i, last)
   local keyword = syntax.keywords[if syntax.caseless then string.lower(word) else word]
   take(last, if keyword then "kw" elseif string.match(word, "^%u") then "type" elseif string.sub(line, last + 1, last + 1) == "(" then "fn" else "plain")
   continue
  end
  _, last = string.find(line, "^%d+", i)
  if last then take(last, "num"); continue end
  take(i, "punct")
 end
 return tokens
end

-- Splits tokens at the edges of `changed`, flagging the pieces inside it.
local function markChanged(tokens: { { string } }, changed: Span?): { Token }
 local out: { Token } = {}
 local pos = 1
 for _, token in tokens do
  local text, kind = token[1], token[2]
  local first, after = pos, pos + #text
  if not changed or changed.from >= changed.to then
   table.insert(out, { text = text, kind = kind, changed = false })
  else
   local cuts = { first }
   if changed.from > first and changed.from < after then table.insert(cuts, changed.from) end
   if changed.to > first and changed.to < after then table.insert(cuts, changed.to) end
   table.insert(cuts, after)
   for k = 1, #cuts - 1 do
    table.insert(out, {
     text = string.sub(text, cuts[k] - first + 1, cuts[k + 1] - first),
     kind = kind,
     changed = cuts[k] >= changed.from and cuts[k] < changed.to,
    })
   end
  end
  pos = after
 end
 return out
end

-- Prepares a file for display: word-diff spans, the whole new-side file as entries, line anchors.
-- `moves` are the file's moved rows by row index, from `Moves.detect`.
function M.analyze(file: Pr.File, moves: { [number]: Move }?): FileDiff
 local entries = buildEntries(file, pairChanges(file.rows, moves or {}), moves or {})
 anchorEntries(entries)
 local extension = Text.extension(file.path)
 local kind = EXTENSIONS[extension]
 return {
  file = file,
  entries = entries,
  syntax = kind and kind.syntax,
  language = kind and kind.language or extension,
  runs = {},
  tokens = {},
  layouts = {},
 }
end

-- The entries a step covers, first to last of the lines of the PR's diff in its range: those
-- numbered within it on its side, and on the new side the removed lines that sit at them. Nil when
-- the range holds none.
function M.stepSpan(fd: FileDiff, step: { side: "new" | "old", from: number, to: number }): Interval?
 local first: number?, last: number? = nil, nil
 for i, entry in fd.entries do
  if entry.diff then
   local row = entry.row
   local line, within
   if step.side == "old" then
    line = row.old
    within = line ~= nil and line >= step.from and line <= step.to
   else
    line = row.new or entry.anchor
    within = line ~= nil and (row.new ~= nil or row.kind == "del") and line >= step.from and line <= step.to
   end
   if within then
    first = first or i
    last = i
   end
  end
 end
 if first and last then return { first = first, last = last } end
 return nil
end

-- The part of new-side lines from..to one GitHub review comment can cover: the lines of the PR's
-- diff in the last hunk that reaches into the range. Nil when no line of the diff is in it.
function M.commentableRange(fd: FileDiff, from: number, to: number): (number?, number?)
 local first, last, inHunk = nil, nil, false
 for _, entry in fd.entries do
  local line = entry.row.new
  if line and line >= from and line <= to then
   if not entry.diff then
    inHunk = false
   elseif not inHunk then
    first, last, inHunk = line, line, true
   else
    last = line
   end
  end
 end
 return first, last
end

-- What a layout of `show` depends on besides the file, as one string.
local function layoutKey(show: Show): string
 local parts = { if show.whole then "whole" else "diff", tostring(show.hit or "") }
 for _, range in show.reveals do table.insert(parts, range.first .. "-" .. range.last) end
 if show.whole then
  local lines = {}
  for line in show.annotated do table.insert(lines, line) end
  table.sort(lines)
  table.insert(parts, table.concat(lines, ","))
 end
 return table.concat(parts, "|")
end

-- The code block as a sequence of line runs, hidden gaps and native runs, in file order. Each
-- block's last layout is kept until what it shows changes, so redrawing the page lays out nothing.
function M.layout(fd: FileDiff, show: Show): Layout
 local base = "all"
 if show.spans then
  local parts = {}
  for _, span in show.spans do table.insert(parts, span.first .. "-" .. span.last) end
  base = table.concat(parts, ",")
 end
 local key = layoutKey(show)
 local kept = fd.layouts[base]
 if kept and kept.key == key then return kept end
 local total = #fd.entries
 local shown, big, openers = shownEntries(fd, show)
 local segments: { Segment } = {}
 local rows = 0
 local i = 1
 while i <= total do
  local first = i
  local visible = shown[i]
  while i <= total and shown[i] == visible do i += 1 end
  local last = i - 1
  if visible then
   table.insert(segments, { kind = "rows", first = first, last = last } :: Rows)
   rows += last - first + 1
  elseif big then
   table.insert(segments, { kind = "native", first = first, last = last } :: Native)
  else
   local following = fd.entries[i]
   table.insert(segments, gapAt(first, last, total, openers[i] or (following and following.label)))
  end
 end
 local layout = { key = key, segments = segments, rows = rows }
 fd.layouts[base] = layout
 return layout
end

-- The run of lines each shown entry is drawn in, as the entry the run starts at. A run starts at the
-- first line of a rows segment, at an entry in `breaks` (where a shared block's steps start and
-- end), and on the line after one a comment card hangs under (`carded`, by new-side line). The page
-- draws its runs from this and names a line's node from it, so the two can't disagree.
function M.runStarts(fd: FileDiff, segments: { Segment }, breaks: { [number]: boolean }, carded: { [number]: boolean }): { [number]: number }
 local starts = {}
 for _, segment in segments do
  if segment.kind ~= "rows" then continue end
  local first = segment.first
  for i = segment.first, segment.last do
   if i > segment.first then
    local above = fd.entries[i - 1].row.new
    if breaks[i] or (above ~= nil and carded[above]) then first = i end
   end
   starts[i] = first
  end
 end
 return starts
end

-- The text of entries first..last, joined once per run.
function M.runText(fd: FileDiff, first: number, last: number): string
 local key = first .. "-" .. last
 local text = fd.runs[key]
 if not text then
  local lines = table.create(last - first + 1)
  for i = first, last do table.insert(lines, fd.entries[i].row.text) end
  text = table.concat(lines, "\n")
  fd.runs[key] = text
 end
 return text
end

-- Colored pieces of entry `i` of a file with a syntax, tokenized once.
function M.tokens(fd: FileDiff, i: number): { Token }
 local entry = fd.entries[i]
 local tokens = fd.tokens[i]
 if not tokens then
  tokens = markChanged(tokenize(entry.row.text, fd.syntax :: Syntax), entry.changed)
  fd.tokens[i] = tokens
 end
 return tokens
end

return M
