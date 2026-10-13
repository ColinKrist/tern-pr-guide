--!strict
-- Move detection: finds code the PR cut from one place and pasted in another, so a block that only
-- moved reads as moved and not as a red block plus a green one. Matches whole runs of removed and
-- added lines by their trimmed text, across files and within one file.
local Pr = require("./pr")

-- Where the other half of a moved line is: for a removed line the new-side line it went to, for an
-- added line the old-side line it came from. `start` marks the first line of a moved block.
export type Move = { path: string, line: number, start: boolean }
-- Moves by file path, then by index into that file's `rows`.
export type Moves = { [string]: { [number]: Move } }

-- A block is a move when it has at least this many non-blank lines...
local MIN_LINES = 3
-- ...of which at least this many are more than punctuation or a bare `end`/`else`...
local MIN_SIGNIFICANT = 2
-- ...and those carry at least this many characters.
local MIN_CHARS = 30
-- Same-text lines tried as the other half of a block, so a line that repeats thousands of times
-- doesn't make every start expensive.
local MAX_CANDIDATES = 24

local CLOSERS: { [string]: boolean } = {}
for word in string.gmatch("end else elseif fi done endif then do begin", "%S+") do CLOSERS[word] = true end

type Item = {
 text: string,
 path: string,
 -- Index into the file's `rows`.
 row: number,
 -- The old-side line of a removed item, the new-side line of an added one.
 line: number,
 -- Consecutive removed (or added) rows share a run; blank rows stay inside it.
 run: number,
 -- For an added item, the run of removed rows directly before its run: one change group, which
 -- the word diff pairs line with line.
 after: number?,
 used: boolean,
}

local function isSpace(byte: number): boolean
 return byte == 32 or (byte >= 9 and byte <= 13)
end

local function normalize(text: string): string
 local first = string.find(text, "%S")
 if not first then return "" end
 local last = #text
 while isSpace(string.byte(text, last)) do last -= 1 end
 return string.sub(text, first, last)
end

-- A line with nothing in it worth matching on: only punctuation, or a bare keyword closer.
local function trivial(text: string): boolean
 local core = string.gsub((string.gsub(text, "^[%p%s]+", "")), "[%p%s]+$", "")
 return core == "" or CLOSERS[core] == true
end

local function qualifies(items: { Item }, first: number, len: number): boolean
 if len < MIN_LINES then return false end
 local significant, chars = 0, 0
 for i = first, first + len - 1 do
  local text = items[i].text
  if not trivial(text) then
   significant += 1
   chars += #text
  end
 end
 return significant >= MIN_SIGNIFICANT and chars >= MIN_CHARS
end

-- How many lines match from removed item `i` and added item `p` on, within their runs.
local function extent(dels: { Item }, i: number, adds: { Item }, p: number): number
 local d, a = dels[i], adds[p]
 if a.used or a.after == d.run then return 0 end
 local len = 1
 while true do
  local nd, na = dels[i + len], adds[p + len]
  if not nd or not na or nd.run ~= d.run or na.run ~= a.run or na.used or nd.text ~= na.text then break end
  len += 1
 end
 return len
end

-- Fills in the moves of one side: `len` items from `mine[i]`, each paired with `theirs[p + k]`. Blank
-- rows between the lines take the counterpart of the line after them.
local function record(result: Moves, mine: { Item }, i: number, theirs: { Item }, p: number, len: number)
 local first = mine[i]
 local byRow = result[first.path]
 if not byRow then
  byRow = {}
  result[first.path] = byRow
 end
 local last = first.row - 1
 for k = 0, len - 1 do
  local item, other = mine[i + k], theirs[p + k]
  for row = last + 1, item.row - 1 do byRow[row] = { path = other.path, line = other.line, start = false } end
  byRow[item.row] = { path = other.path, line = other.line, start = k == 0 }
  last = item.row
 end
end

local M = {}

-- The moves between the removed and added lines of `files`. A run of removed lines pairs with a run
-- of added lines of the same trimmed text, blank lines ignored, as long as it is long enough to not
-- be a coincidence (see MIN_LINES). A block with an edited line in the middle matches as two blocks
-- on either side of that line, and a half too short to count stays an ordinary change. A removed
-- run and the added run right after it are one change group and never match each other.
function M.detect(files: { Pr.File }): Moves
 local dels: { Item }, adds: { Item } = {}, {}
 local addsByText: { [string]: { number } } = {}
 local run = 0
 for _, file in files do
  local prevKind: string? = nil
  local afterRun: number? = nil
  for index, row in file.rows do
   if row.kind == "hunk" then
    prevKind = nil
   else
    local kind = row.kind
    if kind == "del" or kind == "add" then
     if kind ~= prevKind then
      run += 1
      afterRun = if kind == "add" and prevKind == "del" then run - 1 else nil
     end
     local text = normalize(row.text)
     if text ~= "" then
      if kind == "del" then
       table.insert(dels, { text = text, path = file.path, row = index, line = row.old or 0, run = run, used = false })
      else
       table.insert(adds, { text = text, path = file.path, row = index, line = row.new or 0, run = run, after = afterRun, used = false })
       local same = addsByText[text]
       if not same then
        same = {}
        addsByText[text] = same
       end
       table.insert(same, #adds)
      end
     end
    end
    prevKind = kind
   end
  end
  -- A run never continues into the next file.
  run += 1
 end

 local result: Moves = {}
 local i = 1
 while i <= #dels do
  local best, bestLen = 0, 0
  local candidates = if trivial(dels[i].text) then nil else addsByText[dels[i].text]
  if candidates then
   local tried = 0
   for _, p in candidates do
    if adds[p].used then continue end
    local len = extent(dels, i, adds, p)
    if len > bestLen then best, bestLen = p, len end
    tried += 1
    if tried >= MAX_CANDIDATES then break end
   end
  end
  if bestLen > 0 and qualifies(dels, i, bestLen) then
   record(result, dels, i, adds, best, bestLen)
   record(result, adds, best, dels, i, bestLen)
   for k = best, best + bestLen - 1 do adds[k].used = true end
   i += bestLen
  else
   i += 1
  end
 end
 return result
end

return M
