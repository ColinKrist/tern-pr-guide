# PR Guide

A Tern plugin (Luau and one stylesheet) that turns a GitHub PR into a guided review. `README.md` is the user manual. `GUIDE.md` is the guide-file contract.

## Where code goes

Each module's header comment names its one job. Put new code in the module that comment already covers. If none covers it, make a new module with its own header comment.

- **Host:** `src/host.luau` is the only module outside `src/view/` that reads `tern`. Its `Host` table holds the platform calls (processes, kv, files, JSON, timers, environment, clocks, plugin folders); other modules call `Host.kv.get(...)` and the like, and tests swap its fields.
- **Boundary:** only `src/fetch.luau`, `src/prdata.luau`, `src/agent-host.luau`, `src/tandem.luau` and `src/github.luau` reach outside the plugin. `fetch.luau`: the command runners on the reader's shell PATH (`Fetch.run`, `Fetch.git`, `Fetch.runner`), checkouts and saved copies, guide and lens files, and `Host.kv`. `prdata.luau`: reading a PR and posting a review with `gh` and `git`; its public functions are what the web port replaces with GitHub API calls. `agent-host.luau`: the reader's agent (`omp`) and agent fixes. `tandem.luau`: Tandem's CLI and database, plugin-only (the web port leaves it out). `github.luau`: GitHub, only through the runner it is given (`Fetch.runner` in the plugin). prdata, agent-host and tandem run commands only through fetch's runners.
- **Glue:** `src/block.luau` and `src/hub/block.luau` turn clicks and keys into one `ACTIONS` table. A new action is one `ACTIONS` entry, sent by both clicks and `keys.luau`. A hub action that is a workflow lives in the hub module for its job, and its entry calls it: `hub/ops.luau` (GitHub and agent actions on a PR), `hub/agent-run.luau` (an agent fix's flight), `hub/details.luau` (what the fixes and review fix pages read), `hub/tandem.luau` (Tandem's watch and hand-off, plugin-only), `hub/refresh.luau` (the probe, refresh and checks timers) and `hub/lookups.luau` (merge methods, flake evidence). They build on `hub/store.luau` (the shared cache and the Tandem ownership guard) and `hub/runtime.luau` (the `Block` record, drawing, frame ops, arrival alerts). Window effects go through `cx` and `Host.timer` only, and no module requires `hub/block.luau`.
- **Views:** `src/view/*.luau` turn state into nodes and nothing else, and may call `tern.ui`. Build them with `Ui.el` and `Ui.span`, and a text field's input with `Ui.field`.
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
