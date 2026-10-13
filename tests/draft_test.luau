--!strict
-- The review pass's file: what parses, and how its comments and summary land on a page already shown.
local Guide = require("../src/guide")
local Pr = require("../src/pr")
local Review = require("../src/review")
local State = require("../src/state")

local function pr(): Pr.PR
	local rows: { Pr.Row } = { { kind = "hunk", oldStart = 1, newStart = 1 } :: Pr.Hunk }
	for i = 1, 4 do table.insert(rows, { kind = "add", text = "line " .. i, new = i } :: Pr.Line) end
	local file: Pr.File = { path = "src/a.ts", status = "modified", adds = 4, dels = 0, rows = rows }
	return { repo = "acme/api", number = 7, title = "t", body = "", url = "", author = "a", baseRef = "main", head = "abc", files = { file } }
end

local function comment(id: string, line: number): any
	return { id = id, file = "src/a.ts", line = line, kind = "question", body = "Why " .. id .. "?" }
end

local function ids(comments: { Guide.Comment }): string
	local out = {}
	for _, c in comments do table.insert(out, c.id) end
	return table.concat(out, ",")
end

local function parsing()
	local p = pr()
	assert(Guide.parseDraft({ schema = 2, comments = {} }, p) == nil, "another schema isn't a review file")
	assert(Guide.parseDraft("comments", p) == nil, "a string isn't a review file")
	local draft = Guide.parseDraft({
		schema = 1, author = "opus-5", lens = "Security", summary = "Looks fine.",
		comments = { comment("c1", 2), comment("c2", 99), { id = "c3", file = "nope.ts", line = 1, kind = "nit", body = "x" } },
	}, p)
	assert(draft, "a review file parses")
	assert(ids(draft.comments) == "c1", "comments off the diff are dropped: " .. ids(draft.comments))
	assert(draft.author == "opus-5" and draft.lens == "Security" and draft.summary == "Looks fine.")
	local bare = Guide.parseDraft({ schema = 1 }, p)
	assert(bare and #bare.comments == 0 and bare.summary == "" and bare.lens == nil, "missing comments and summary are empty")
end

local function reviewWins()
	local p = pr()
	local guide = Guide.parse({
		schema = 1, author = "haiku-4", lens = "Balanced", summary = "Inline summary.", overview = "Over.",
		changes = { { title = "Do it", why = "", steps = { { file = "src/a.ts", from = 1, to = 2, title = "Step", note = "" } } } },
		comments = { comment("inline", 1) },
	}, p)
	assert(guide and guide.guided)
	local draft = Guide.parseDraft({ schema = 1, author = "opus-5", lens = "Security", summary = "Review summary.", comments = { comment("r1", 3) } }, p)
	assert(draft)
	local merged = Guide.withDraft(guide, draft)
	assert(ids(merged.comments) == "r1", "the review file's comments replace inline ones")
	assert(merged.summary == "Review summary." and merged.author == "opus-5" and merged.lens == "Security")
	assert(merged.overview == "Over." and merged.guided and #merged.changes == 1, "the explanation stays")
	assert(ids(guide.comments) == "inline", "the guide it merged into is left as it was")
end

local function onThePage()
	local p = pr()
	local guide = Guide.parse({ schema = 1, changes = { { title = "Do it", steps = { { file = "src/a.ts", from = 1, to = 2, title = "Step", note = "" } } } } }, p)
	assert(guide)
	local draft = Guide.parseDraft({ schema = 1, author = "opus-5", summary = "Drafted.", comments = { comment("r1", 3) } }, p)
	assert(draft)

	local s = State.new(p, guide, {})
	State.mergeDraft(s, draft)
	assert(s.review.summary.text == "Drafted.", "an untouched summary takes the drafted one")
	assert(ids(s.review.guide.comments) == "r1" and Review.counts(s.review).waiting == 1, "the comments wait for the reader")
	State.switchView(s, "files")
	assert(ids(s.review.guide.comments) == "r1", "the file view has them too")

	local edited = State.new(p, guide, {})
	edited.review.summary.text = "My own words."
	State.mergeDraft(edited, draft)
	assert(edited.review.summary.text == "My own words.", "a summary the reader edited is kept")
	assert(ids(edited.review.guide.comments) == "r1")

	local typing = State.new(p, guide, {})
	typing.editingSummary = true
	State.mergeDraft(typing, draft)
	assert(typing.review.summary.text == "", "a summary being edited is kept")

	local plain = State.new(p, Guide.defaultGuide(p), {})
	State.mergeDraft(plain, draft)
	assert(ids(plain.review.guide.comments) == "r1" and plain.review.summary.text == "Drafted.", "the default walkthrough takes a review too")
end

-- The explanation replacing the default walkthrough keeps what the reader wrote there.
local function carriedOver()
	local p = pr()
	local guide = Guide.parse({ schema = 1, summary = "Drafted.", changes = { { title = "Do it", steps = { { file = "src/a.ts", from = 1, to = 2, title = "Step", note = "" } } } } }, p)
	assert(guide)
	local before = State.new(p, Guide.defaultGuide(p), {})
	Review.addOwn(before.review, "src/a.ts", 2, 2, "Mine.")
	local after = State.new(p, guide, {})
	State.carryOver(before, after)
	assert(#after.review.own == 1 and after.review.summary.text == "Drafted.", "an untouched summary takes the new guide's")
	before.review.summary.text = "Edited."
	local again = State.new(p, guide, {})
	State.carryOver(before, again)
	assert(again.review.summary.text == "Edited.", "an edited summary is kept")
end

return function()
	parsing()
	reviewWins()
	onThePage()
	carriedOver()
end
