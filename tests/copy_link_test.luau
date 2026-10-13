--!strict
-- Fetch.copyLink: one `osascript` call carrying the title and URL as arguments (never spliced into the script), and
-- why it failed when it did. The runner is replaced by a recorder.
local Fetch: any = require("../src/fetch")

return function()
	local calls: { { string } } = {}
	local reply: any = { status = 0, stdout = "", stderr = "", timed_out = false }
	Fetch.runner = function(argv: { string }, _opts: any, done: (any) -> ())
		table.insert(calls, argv)
		done(reply)
	end

	local err: string? = "unset"
	Fetch.copyLink('Fix <b> & "x"', "https://github.com/a/b/pull/1", function(e) err = e end)
	assert(err == nil, "a clean exit is a success")
	local argv = calls[1]
	assert(argv[1] == "osascript" and argv[2] == "-l" and argv[3] == "JavaScript" and argv[4] == "-e")
	assert(argv[6] == 'Fix <b> & "x"' and argv[7] == "https://github.com/a/b/pull/1", "title and URL ride as arguments")
	assert(not string.find(argv[5], "pull/1", 1, true), "the script holds neither")

	reply = { status = 1, stdout = "", stderr = "boom\nmore", timed_out = false }
	Fetch.copyLink("t", "u", function(e) err = e end)
	assert(err ~= nil and string.find(err, "boom", 1, true), "stderr's first line is the reason")

	reply = { status = -1, stdout = "", stderr = "", timed_out = true }
	Fetch.copyLink("t", "u", function(e) err = e end)
	assert(err == "the clipboard didn't answer")
end
