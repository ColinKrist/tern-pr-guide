--!strict
-- Hub agent work: loading-row timing and formatting, the saved conversation a conflict fix keeps for Open agent chat,
-- a fix the chat moved (re-read, reviewed again, Push locked until it is), and the chat link the window resumes.
-- Pure modules and recorded fixtures only.
local Agent = require("../src/agent")
local AgentFix = require("../src/hub/agent-fix")
local Keys = require("../src/keys")
local Links = require("../src/links")
local Progress = require("../src/view/progress")
local ReviewFix = require("../src/hub/review-fix")
local State = require("../src/hub/state")
local Cards: any = require("../fixtures/hub/agent-cards")
local Fixture: any = require("../fixtures/hub/review-fix")

local SESSION = "/plugin-data/agent-sessions/acme-web-1803-1791590400-1"
local CHAT_COMMIT = string.rep("d", 40)

-- The worktree after a chat: the cache conflict's resolution rewritten, and a line added below the note props.
local CHAT_FILES = {
	["src/fonts.ts"] = "// loader\nshared\nmain manifest\nbranch range\n  combine(range, manifest);\n// end loader\n\n// cache\nconst cache = combineCaches({ warm: true });\n// end cache\nconst unrelated = true;\n",
	["src/note.ts"] = "type Props = {\ntitle: string;\nscript?: string;\nlessonId: string;\n};\nexport const unrelated = 42;\nexport const added = 1;\n",
}
local CHAT_DIFF = table.concat({
	"diff --git a/src/fonts.ts b/src/fonts.ts",
	"index 1111111..2222222 100644",
	"--- a/src/fonts.ts",
	"+++ b/src/fonts.ts",
	"@@ -6,6 +6,6 @@",
	" // end loader",
	" ",
	" // cache",
	"-const cache = combineCaches();",
	"+const cache = combineCaches({ warm: true });",
	" // end cache",
	" const unrelated = true;",
	"diff --git a/src/note.ts b/src/note.ts",
	"index 3333333..4444444 100644",
	"--- a/src/note.ts",
	"+++ b/src/note.ts",
	"@@ -4,3 +4,4 @@",
	" lessonId: string;",
	" };",
	" export const unrelated = 42;",
	"+export const added = 1;",
	"",
}, "\n")

local function withSession(): AgentFix.Fix
	local fix = table.clone(Fixture.fix) :: AgentFix.Fix
	fix.session = SESSION
	return fix
end

local function press(s: State.State, name: string, shift: boolean?): any
	return Keys.hubAction(s, { name = name, shift = shift == true, meta = false, ctrl = false, alt = false } :: any)
end

local function progress()
	assert(Agent.clock(0) == "0:00" and Agent.clock(67) == "1:07" and Agent.clock(3600) == "60:00")
	assert(Agent.clock(-4) == "0:00" and Agent.clock(9.9) == "0:09", "the clock counts whole seconds and never runs backwards")
	assert(Progress.step(0, 120) == 0 and Progress.step(-30, 120) == 0)
	assert(Progress.step(120, 120) == 45, "about 90% at the expected length")
	assert(Progress.step(10_000, 120) == 48, "never past 95% before the run ends")
end

local function sessions()
	-- The conflict agent's conversation is recorded on the run once the agent starts, then on the fix.
	local run = Cards.run(Cards.runningKey)
	for _, event in Cards.events() do
		local outcome = AgentFix.step(run, event)
		if outcome.kind == "running" then
			run = outcome.run
		elseif outcome.kind == "ready" then
			assert(outcome.fix.session == "/plugin-data/agent-sessions/acme-web-1802" and outcome.fix.origin == nil)
		end
	end
	local early = Cards.run(Cards.keys.idle)
	local failed = AgentFix.step(early, { kind = "failed", reason = "worktree" })
	assert(failed.kind == "failed" and failed.session == nil, "a failure before the agent started has no conversation")
	local started = AgentFix.step(early, { kind = "stage", stage = "agent" })
	assert(started.kind == "running" and started.run.session ~= nil)
	local after = AgentFix.step(started.run, { kind = "failed", reason = "agent stopped" })
	assert(after.kind == "failed" and after.session == started.run.session)
	-- A bot worker runs with --no-session: no conversation to resume.
	local spec = Cards.spec(Cards.keys.idle)
	spec.input = { kind = "bot", details = Fixture.details }
	local bot = AgentFix.step(AgentFix.bind(AgentFix.start(Cards.keys.idle, Cards.asOf), spec), { kind = "stage", stage = "agent" })
	assert(bot.kind == "running" and bot.run.session == nil)
end

local function chatFix(): AgentFix.Fix
	local hunks = AgentFix.chatHunks(CHAT_DIFF)
	assert(hunks and #hunks == 2 and hunks[1].id == "chat:1" and hunks[2].id == "chat:2" and hunks[2].path == "src/note.ts")
	assert(#(AgentFix.chatHunks("") :: any) == 0, "a chat that changed nothing adds no hunks")
	assert(AgentFix.chatHunks("diff --git a/x b/x\ndeleted file mode 100644\n") == nil, "a deletion can't be reviewed here")

	local fix = withSession()
	local cache = fix.hunks[2]
	assert(AgentFix.reanchor(cache, Fixture.files["src/fonts.ts"]) == cache, "an untouched resolution is kept as it is")
	local moved = AgentFix.reanchor(cache, CHAT_FILES["src/fonts.ts"])
	assert(moved and moved ~= cache and moved.resolved and #moved.resolved.lines == 1)
	assert(moved.resolved.lines[1].text == "const cache = combineCaches({ warm: true });" and moved.resolved.lines[1].tag == "agent")
	assert(AgentFix.reanchor(cache, CHAT_FILES["src/fonts.ts"] .. CHAT_FILES["src/fonts.ts"]) == nil, "ambiguous context fails closed")
	assert(AgentFix.reanchor(cache, "// cache\nnothing after\n") == nil, "missing context fails closed")
	-- Found live: the chat edited a line of the recorded context (line five), not the resolution. The context nearest the
	-- conflict still marks it, and the hunk keeps the agent's resolution with the context that still matches.
	local edge: AgentFix.ConflictHunk = {
		id = "h1", path = "chat-conflict.txt", start = 3, base = { "line three" }, ours = { "line three, topic" }, theirs = { "line three, main" },
		context = { before = { "line one", "line two" }, after = { "line four", "line five" } }, subjects = { ours = {}, theirs = {} },
		resolved = { by = "agent", lines = { { tag = "ours", text = "line three, topic" }, { tag = "theirs", text = "line three, main" } } },
	}
	local edited = AgentFix.reanchor(edge, "line one\nline two\nline three, topic\nline three, main\nline four\nline five, edited in the chat.\n")
	assert(edited and edited.resolved == edge.resolved and #edited.context.after == 1 and edited.context.after[1] == "line four")
	local review = ReviewFix.build({ worktree = "/w", branch = "b", base = "main", headOid = string.rep("a", 40), commit = string.rep("b", 40),
		hunks = { edited :: AgentFix.ConflictHunk }, summary = "", usedAgent = true },
		{ ["chat-conflict.txt"] = "line one\nline two\nline three, topic\nline three, main\nline four\nline five, edited in the chat.\n" }, nil)
	assert(review.verified, review.error)

	local updated, why = AgentFix.fromChat(fix, CHAT_COMMIT, CHAT_FILES, CHAT_DIFF)
	assert(updated and not why)
	assert(updated.commit == CHAT_COMMIT and updated.origin == fix.commit and updated.session == SESSION and updated.worktree == fix.worktree)
	assert(#updated.hunks == 5 and updated.hunks[1] == fix.hunks[1] and updated.hunks[3] == fix.hunks[3] and AgentFix.isChat(updated.hunks[5]))
	-- A second chat diffs from the agent's own commit again, so chat hunks never pile up.
	local again = AgentFix.fromChat(updated, string.rep("e", 40), CHAT_FILES, CHAT_DIFF)
	assert(again and again.origin == fix.commit and #again.hunks == 5)
	local broken = table.clone(CHAT_FILES)
	broken["src/fonts.ts"] = "// cache rewritten\n"
	local none, reason = AgentFix.fromChat(fix, CHAT_COMMIT, broken, CHAT_DIFF)
	assert(none == nil and reason and string.find(reason, "src/fonts.ts", 1, true))

	-- Review fix reads the chat's commit like any fix: chat hunks need no journal entry and may sit beside a conflict.
	local originals: { [string]: ReviewFix.Original } = {}
	for _, hunk in fix.hunks do originals[hunk.id] = { path = hunk.path, start = hunk.start, base = hunk.base, ours = hunk.ours, theirs = hunk.theirs } end
	local review = ReviewFix.build(updated, CHAT_FILES, Fixture.details, originals)
	assert(review.verified and #review.hunks == 5, review.error)
	assert(not ReviewFix.build(updated, Fixture.files, Fixture.details, originals).verified, "the agent's files are not the chat's commit")
	return updated
end

local function reviewAgain(updated: AgentFix.Fix)
	local key = Fixture.key
	local s = State.new(Fixture.prs, Fixture.asOf, nil)
	local fix = withSession()
	s.agents[key] = { kind = "ready", fix = fix, reviewed = { ["fonts-loader"] = true, ["fonts-cache"] = true, ["note-props"] = true } }
	State.project(s)
	local card = State.card(s, key) :: State.Card
	assert(card.main and card.main.label == "Review" and card.main.act == "open" and card.chips[1].text == "Fix ready")
	assert(card.more[1].act == "card-agent-chat" and card.more[1].key == "⇧O" and card.more[2].act == "card-agent-worktree")
	State.select(s, key)
	local chat = press(s, "o", true)
	assert(chat and chat.act == "card-agent-chat" and chat.value == key, "⇧O and the menu row send the same action")
	local open = press(s, "o")
	assert(open and open.act == "card-agent-worktree")

	-- Only a new commit in the same retained worktree, and never once Push or Discard began.
	local elsewhere = table.clone(updated)
	elsewhere.worktree = "/pool/other"
	assert(not State.chatUpdated(s, key, elsewhere) and not State.chatUpdated(s, key, fix))
	local ready = s.agents[key] :: any
	ready.completion = "push"
	assert(not State.chatUpdated(s, key, updated))
	ready.completion = nil
	assert(State.chatUpdated(s, key, updated))
	local agent = s.agents[key] :: any
	assert(agent.kind == "ready" and agent.fix == updated and next(agent.reviewed) == nil and agent.review == nil, "nothing reviewed carries over")
	card = State.card(s, key) :: State.Card
	assert(card.chips[1].text == "Review again" and card.chips[1].kind == "wait")
	assert(card.main and card.main.label == "Review again" and card.agentMessage == "Fix updated from chat · ddddddd")

	-- Push stays locked until every hunk of the new commit is reviewed, and then pushes exactly that commit.
	assert(State.openReviewFix(s, key))
	agent.review = ReviewFix.build(updated, CHAT_FILES, Fixture.details)
	local route = s.route :: State.Route
	route.loading = false
	local page = State.reviewPage(s) :: State.ReviewPage
	assert(page and not page.all and page.count == 0)
	local plan, problem = ReviewFix.plan("push", State.reviewRequest(s) :: ReviewFix.Request)
	assert(plan == nil and problem == "review every conflict first")
	local chatKey = press(s, "o", true)
	assert(chatKey and chatKey.act == "card-agent-chat" and chatKey.value == key)
	for index in updated.hunks do State.reviewToggle(s, index) end
	assert((State.reviewPage(s) :: State.ReviewPage).all)
	plan = ReviewFix.plan("push", State.reviewRequest(s) :: ReviewFix.Request)
	assert(plan and plan.command and plan.command.argv[#plan.command.argv] == CHAT_COMMIT .. ":refs/heads/topic")
end

local function failedChat()
	local key = Cards.keys.failed
	local s = State.new(Cards.prs, Cards.asOf, nil)
	State.agentFailed(s, key, "Agent stopped", "/pool/acme/web/wt-1", true, SESSION)
	local card = State.card(s, key) :: State.Card
	assert(card.main and card.main.label == "Try again")
	assert(card.more[1].act == "card-agent-worktree" and card.more[2].act == "card-agent-chat")
	-- A later failure (the lease return) keeps the conversation.
	State.agentFailed(s, key, "Couldn't return the worktree lease", nil, false)
	local agent = s.agents[key] :: any
	assert(agent.session == SESSION)
	local session, cwd = State.chatOf(agent)
	assert(session == SESSION and cwd == nil, "a returned worktree is never where a chat runs")
	card = State.card(s, key) :: State.Card
	assert(#card.more == 1 and card.more[1].act == "card-agent-chat")
	State.openFixes(s, key)
	local pressed = press(s, "o", true)
	assert(pressed and pressed.act == "card-agent-chat" and pressed.value == key, "the fixes page sends the card's action")
	State.closeFixes(s)
	-- One owner per branch: no chat on a PR Tandem watches.
	for _, pr in s.prs do if pr.key == key then pr.tandem = true end end
	State.agentFailed(s, key, "Agent stopped", "/pool/acme/web/wt-1", true, SESSION)
	for _, more in (State.card(s, key) :: State.Card).more do assert(more.act ~= "card-agent-chat") end
end

local function work()
	local s = State.new(Cards.prs, Cards.asOf, nil)
	local key = Cards.keys.idle
	assert(not State.working(s))
	assert(State.beginAgent(s, key, Cards.asOf))
	State.startTiming(s, key, Cards.asOf, 240)
	State.project(s)
	local card = State.card(s, key) :: State.Card
	assert(State.working(s) and card.work and card.work.phrase == "Preparing worktree…" and card.work.since == Cards.asOf and card.work.expected == 240)
	assert(State.agentEvent(s, key, Cards.events()[2]))
	card = State.card(s, key) :: State.Card
	assert(card.work and card.work.phrase == "Merging base branch…", "each stage's phrase writes in")
	assert(State.agentOutcome(s, key, { kind = "stopped" }) and not State.working(s))

	local other = Cards.keys.failed_no_worktree
	State.startTiming(s, other, Cards.asOf + 5, 45)
	State.setBusy(s, other, State.SUMMARIZING)
	card = State.card(s, other) :: State.Card
	assert(State.working(s) and card.work and card.work.phrase == "Summarizing feedback…" and card.work.since == Cards.asOf + 5)
	State.setBusy(s, other, nil)
	assert(not State.working(s) and (State.card(s, other) :: State.Card).work == nil)
end

local function links()
	local sessions = "/data/agent-sessions"
	assert(Links.chatRoute(Links.chatLink("acme-web-1803-17-2")) == "acme-web-1803-17-2")
	assert(Links.chatRoute("https://github.com/#prguide-chat=../../etc") == nil and Links.chatRoute("https://github.com/acme/web/pull/1") == nil)
	local record = { dir = sessions .. "/acme-web-1803-17-2", cwd = "/pool/acme/web/wt 1", command = "/Users/o'neil/bin/omp" }
	local launch = Links.chatLaunch(record, "acme-web-1803-17-2", sessions)
	assert(launch and launch.cwd == "/pool/acme/web/wt 1")
	assert(launch.command == "'/Users/o'\\''neil/bin/omp' --session-dir '/data/agent-sessions/acme-web-1803-17-2' --continue")
	-- Only a record the hub writes: its own conversation folder, an absolute folder, an omp executable.
	assert(Links.chatLaunch(record, "other", sessions) == nil)
	assert(Links.chatLaunch({ dir = record.dir, cwd = "relative", command = record.command }, "acme-web-1803-17-2", sessions) == nil)
	assert(Links.chatLaunch({ dir = record.dir, cwd = record.cwd, command = "/bin/sh" }, "acme-web-1803-17-2", sessions) == nil)
	assert(Links.chatLaunch(nil, "acme-web-1803-17-2", sessions) == nil)
end

return function()
	progress()
	sessions()
	reviewAgain(chatFix())
	failedChat()
	work()
	links()
end
