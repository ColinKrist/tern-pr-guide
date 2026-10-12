# PR Guide

A Tern plugin (Luau and one stylesheet) with two surfaces: the PR hub organizes pull requests across repositories, and the guide walks through one pull request and posts one review.

## Product map

- `README.md` is the user manual and key reference.
- `GUIDE.md` is the saved guide-file contract.
- `docs/hub/README.md` is the PR hub's product and architecture spec. Before changing the hub, read **Product decisions**, **Shared Luau contracts**, **How this maps onto Tern** and **Verification**.

| Feature | Code |
|---|---|
| Hub columns, reasons and priority | `src/hub/model.luau` |
| Hub selection, filters, search and prepared board | `src/hub/state.luau` |
| Cache, refresh scheduling, recent PRs and merge settings | `src/hub/sync.luau` |
| GitHub commands and response parsing | `src/github.luau` |
| Processes, files, kv and worktree effects | `src/fetch.luau` |
| Hub actions, callbacks and window effects | `src/hub/block.luau` |
| Fixes page, agent fixes, review-before-push and summaries | `src/hub/fixes.luau`, `src/hub/agent-fix.luau`, `src/hub/review-fix.luau`, `src/hub/summary.luau` |
| Hub rendering | `src/view/hub/*.luau` |
| Saved guide model and parsing | `src/guide.luau` |
| Guided review interaction state and effects | `src/state.luau`, `src/block.luau` |
| Guided review rendering | `src/view/*.luau` outside `src/view/hub/` |
| Keyboard actions and help | `src/keys.luau`, `src/view/help.luau`, `src/view/hub/help.luau`, README Keys table |
| Shared presentation | `guide.css` |

## Where code goes

Each module's header comment names its one job. Put new code in the module that comment already covers. If none covers it, make a new module with its own header comment.

- **Boundary:** only `src/fetch.luau` and `src/github.luau` reach outside the plugin. `fetch.luau`: `gh`, `git`, `omp`, `tern.kv`, and files. `github.luau`: GitHub, only through the runner it is given (`Fetch.runner` in the plugin).
- **Glue:** only `src/block.luau` and `src/hub/block.luau` do window effects: scrolling, focus, timers, toasts. A new action is one `ACTIONS` entry, sent by both clicks and `keys.luau`.
- **Views:** `src/view/*.luau` turn state into nodes and nothing else. Build them with `Ui.el` and `Ui.span`.
- **Styles:** `guide.css` only, with `gp-` classes and the color tokens `DESIGN.md` names. To change a look, edit the rule where it lives.
- `GUIDE.md`, `prompts/guide.md` and `src/guide.luau` change together.
- Mockups and scratch files go in `/tmp`, except an approved design's reference mockups, which live with its spec (the PR hub's are in `docs/hub/`). A mockup links `docs/tern-tokens.css` (Tern's variable values), then `guide.css`, inside a `.gp-root` wrapper. `docs/screenshots/` is only for README images.

## UI

Read `DESIGN.md` and `docs/ui.md` before any change to `src/view/` or `guide.css`, and before making a mockup. `DESIGN.md` is the visual system: tokens, components, color meanings, and the interaction and density rules. `docs/ui.md` covers how to lay out new components, motion, and what Tern can't render. Before showing any UI to the user, run `docs/ui.md`'s "Before showing UI" checklist.

**Keyboard first.** A new control (button, field, tab, menu, toggle) ships with its keyboard path in the same change, mockups included:

- It has a key, listed in `view/help.luau` (the `?` panel) and the README Keys table, and shown as a `kbd` where `DESIGN.md`'s Keycaps section says.
- A menu or list opened by key works without the mouse: arrows (or `j`/`k`) move, ⏎ chooses, Esc closes, and a keyboard-opened menu appears without animation.
- The key and the click send the same `ACTIONS` entry.
- In the hub, letter keys act only while the search and add-by-link fields are empty, as `j` and `k` do.

## Copy

New UI text sounds official: neutral, plain and short, like GitHub.

| Kind | Pattern | Examples |
|---|---|---|
| Labels, buttons | Sentence case, verb first | "Mark all reviewed", "Request changes" |
| Progress | Present participle plus "…" | "Loading open pull requests…" |
| Failure | "Couldn't …: reason" | "Couldn't open your lenses folder" |
| Empty state | "No …" | "No description provided." |

- Prefer a noun over "you": "Needs attention", "Awaiting author".
- Plain statements: no exclamation marks, emoji or marketing words.
- In the same change, update the README.

## Verify

- `/opt/homebrew/bin/luau tests/run.luau` runs the pure-module tests and exits non-zero on a failed assert. Run it, then `tern plugin reload`.
- `tern plugin reload` exits 1 if the plugin fails to load.
- Try the change in Tern with **New PR Guide sample block**, or a real PR opened with `post=false`. Test reviews are always dry runs.
- Check UI changes in light and dark.

## Commits

The subject is the user-visible behavior as a plain sentence, with no type prefix. Example: "Picker: Recently opened PRs from any repo at the top, so a closed PR is one keypress away".

Main is the release: `tern plugin install github.com/jubbydev/tern-pr-guide` installs whatever main holds. Work on a branch, and bump `version` in `plugin.toml` in the change that lands on main: the patch number for fixes, the minor number for new features. `tern plugin install` and `tern plugin list` report that number, so an unchanged one looks like the update didn't install.
