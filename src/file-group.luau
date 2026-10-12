--!strict
-- Which changed files the page sets apart when no step visits them: tests, found by path, and
-- generated files, which git's `linguist-generated` attribute marks (src/fetch.luau reads it).
export type Group = "tests" | "generated"

-- Directories whose files are tests, compared in lower case: "Tests/" and "Test/" count too.
local TEST_DIRS: { [string]: boolean } = {
 test = true, tests = true, __tests__ = true, spec = true, specs = true, e2e = true,
}

-- A file name is a test's when its stem (the name without its last extension) has something before
-- one of these endings, and, where a list is given, that extension: `foo_test.go`, `foo.test.ts`,
-- `foo.spec.ts`, `foo_spec.rb`, `FooTest.java`, `FooTests.swift`.
local SUFFIXES: { { suffix: string, extensions: { [string]: boolean }? } } = {
 { suffix = "_test" },
 { suffix = ".test" },
 { suffix = ".spec" },
 { suffix = "_spec", extensions = { rb = true } },
 { suffix = "Test", extensions = { java = true, kt = true } },
 { suffix = "Tests", extensions = { swift = true } },
}

local M = {}

M.LABELS = { tests = "Tests", generated = "Generated" } :: { [Group]: string }

-- Whether `path` names a test file: under a test directory, or named like a test.
function M.isTest(path: string): boolean
 local parts = string.split(path, "/")
 local name = table.remove(parts) :: string
 for _, dir in parts do
  if TEST_DIRS[string.lower(dir)] then return true end
 end
 if string.match(name, "^test_.+%.py$") then return true end
 local stem, extension = string.match(name, "^(.+)%.([^.]+)$")
 if not stem then return false end
 for _, rule in SUFFIXES do
  local cut = #stem - #rule.suffix
  if cut > 0 and string.sub(stem, cut + 1) == rule.suffix and (rule.extensions == nil or rule.extensions[extension :: string]) then
   return true
  end
 end
 return false
end

-- The group a changed file belongs to, if any: generated wins over tests.
function M.of(path: string, generated: boolean): Group?
 if generated then return "generated" end
 if M.isTest(path) then return "tests" end
 return nil
end

-- Where the page keeps whether a group is folded: among the folded folders, under a name no folder
-- path can have (paths never start with "/").
function M.foldKey(group: Group): string
 return "/" .. group
end

-- The folded folders a guided page starts with: the groups it sets apart under its supporting changes.
function M.folded(): { [string]: boolean }
 return { [M.foldKey("tests")] = true, [M.foldKey("generated")] = true }
end

return M
