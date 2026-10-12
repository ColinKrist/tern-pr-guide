--!strict
-- The platform calls every non-view module makes: processes, the shared key/value store, files, JSON, timers,
-- the environment, the clocks, the operating system and the plugin's folders. Today they are Tern's (`tern.*`,
-- and `os.time` for the wall clock); nothing outside this file and src/view reads `tern`. Tests swap fields on
-- this one table.

export type Host = {
	process: { run: (argv: { string }, opts: ProcessOptions?, cb: (result: ProcessResult) -> ()) -> () },
	kv: { get: (key: string) -> any, set: (key: string, value: any) -> () },
	fs: {
		read: (path: string, max_bytes: number?) -> string,
		write: (path: string, text: string) -> (),
		list: (path: string) -> { string },
		exists: (path: string) -> boolean,
		mkdir: (path: string) -> (),
		remove: (path: string) -> (),
	},
	json: { encode: (value: any, pretty: boolean?) -> string, decode: (text: string) -> any, array: <T>(t: T) -> T },
	timer: (ms: number, fn: () -> ()) -> TimerHandle,
	getenv: (name: string) -> string?,
	-- Monotonic milliseconds, for measuring how long something took.
	now: () -> number,
	-- Wall-clock seconds since the epoch.
	time: () -> number,
	-- The operating system Tern runs on ("macos", "linux", ...).
	runtime: { os: string },
	plugin: { data: string, dir: string },
}

-- The plain luau test runner has no `tern`: those fields stay nil until a test sets them.
local platform: any = tern or {}

local Host: Host = {
	process = platform.process,
	kv = platform.kv,
	fs = platform.fs,
	json = platform.json,
	timer = platform.timer,
	getenv = platform.getenv,
	now = platform.now,
	time = function(): number return os.time() end,
	runtime = platform.runtime,
	plugin = platform.plugin,
}

return Host
