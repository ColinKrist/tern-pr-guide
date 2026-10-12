# PR Guide

**A Tern plugin for keeping track of pull requests, reading diffs and finishing reviews.**

Most PR work happens in fragments. You open GitHub to check CI, jump to Slack to find the last
thread, reopen the diff, then try to remember which review was waiting on you. This gets rough once
several repositories are moving at the same time.

PR Guide collects that work in Tern. The hub shows your PRs and review requests across repositories.
Open one to read the diff, ask your own agent for a guided walkthrough, leave comments and submit the
review.

![The PR hub showing pull requests that need fixes, are in review and are ready to merge](docs/screenshots/hub.png)

## Install

PR Guide needs Tern and the [GitHub CLI](https://cli.github.com) signed in to GitHub.
[OMP](https://omp.sh) is optional and adds
guided reviews and agent fixes.

```sh
gh auth login
tern plugin install github.com/jubbydev/tern-pr-guide
```

Press `⌥⌘R` in Tern, or choose **PR hub** from the command palette. **New PR hub sample block** opens
recorded sample data if you want to explore before using a real PR.

To work on the plugin itself, clone it and run `tern plugin link /path/to/tern-pr-guide`.

## PR Hub: keep every PR in view

The PR hub answers three questions: which PR needs you, what is holding it up and what can you do
next?

Your own PRs are grouped into **Needs fixes**, **In review** and **Ready to merge**. Review requests
are grouped into **To review**, **Waiting on author** and **Approved**. A card says why it is there,
including requested changes, unresolved comments, failed checks, conflicts and failed merge-queue
runs.

The hub reads from its cache first and refreshes in the background. Press `.` to jump to the next PR
that needs you. Search across repositories, filter the board or sort it by priority, age or size.
Common actions such as re-running checks, updating a branch, requesting another review and merging
are available from the selected card.

When a conflict or bot review needs work, press `A` to start your OMP agent. The agent works in an
isolated worktree and its progress stays on the card. You review the resulting commit before deciding
whether to push it. PRs watched by Tandem can be handed back to their coordinator from the same key.

The hub keeps watching after you move on. Its Tern status-line segment shows how many PRs need fixes
or review, and the board updates when checks, comments or merge state change.

## PR View: read it in Tern

Opening a card gives you a complete PR view inside Tern. A PR that needs fixes opens at the failing
check, comment or conflict first. From there you can read the description, browse files, search
changed code, comment on a line and submit a GitHub review. PR Guide builds the diff with local git,
so large PRs and large files remain responsive.

![The PR file browser with the changed files and description](docs/screenshots/pr-view.png)

The GitHub side is deliberately conservative. The hub renders cached data immediately, uses a
conditional notifications request to look for changes and batches the GraphQL data it needs. Measured
usage is about 220 GraphQL points per hour while the hub is open, compared with GitHub's 5,000-point
hourly limit. Opening a PR reads its metadata once, then uses local git for the diff and source.

## Guided PR Diffs: turn a large diff into a walkthrough

With OMP installed, PR Guide can ask your own agent to organize the PR into a guided review. The
result follows the same basic idea as Linear Diffs: start with the shape of the change, then walk
through it in small pieces.

The guide begins with a plain-language overview and an optional before-and-after diagram. It groups
the work into a few changes, then pins each explanation beside the exact lines it describes. `j` and
`k` move between steps, and `⏎` marks the current step reviewed.

![A guided review with an overview, diagram and the first change](docs/screenshots/overview.png)

Each step stays small enough to reason about. Related files are listed together, removed lines remain
visible and suggested comments sit beside the code that prompted them. Press `t` whenever you want to
switch between **Guided** and **Files**.

![A guided step with its code and a suggested review comment](docs/screenshots/step.png)

Guides are saved with the repository, so reopening the PR is immediate. Worktrees share the same
saved guide.

## AI Review: use your own model and lens

Choose the model, effort and review lens before starting a guided review. The built-in lenses cover
different jobs:

- **Balanced** explains the whole PR and keeps the useful comments.
- **Security** reads the change from an attacker's perspective.
- **Architecture** looks at boundaries, dependencies and long-term cost.
- **Quick skim** gives you the shape of the PR and the comments that matter most.
- **Teaching** explains the code for someone new to the project.

![Choosing an OMP model, effort and review lens](docs/screenshots/lenses.png)

Choose **Edit lenses…** or press `⌃E` to add one. Each custom lens is a Markdown file in your lenses
folder:

```markdown
# Performance

Looks for slow paths and wasted work.

Check for repeated work in loops, unnecessary copying, blocking calls on hot paths and queries that
could be batched. Comment only when the cost will matter in practice.
```

A custom lens with the same name as a built-in lens replaces it. PR Guide still controls the guide's
shape, so every lens produces a review the interface can open.

## Finish the review

Suggested comments begin as drafts. Keep the ones you agree with, dismiss the rest and write your own
on any changed line. Press `r` to open the review panel, choose Comment, Approve or Request changes,
edit the summary and submit everything as one GitHub review.

![The review panel with comments, summary and verdict](docs/screenshots/review.png)

Submitting asks for confirmation. If the PR received new commits while you were reading, PR Guide
stops and asks you to refresh first. The sample page uses a dry run and saves its review under `/tmp`.

## A typical pass through the queue

1. Press `⌥⌘R` to focus the hub.
2. Press `.` to select the next PR that needs you.
3. Use the card action, or press `⏎` to open the PR.
4. Read with `j` and `k`, mark steps with `⏎` and add comments with `c`.
5. Press `r` to finish the review, then return to the hub for the next card.

Press `⌥⇧⌘R` to open the hub in AI-guide mode. In that mode `⏎` starts a guided review for a PR
without a saved guide. `⇧⏎` does the same from any card.

## Keyboard reference

Press `?` on any PR Guide page for the shortcuts that apply there.

### PR hub

| Key | Action |
|---|---|
| `h` `j` `k` `l` or arrows | Move between cards |
| `.` | Select the next PR that needs you |
| `⏎` | Open the PR, its fixes page or a ready agent fix |
| `⇧⏎` | Open and start a guided review |
| `T` | Switch between your PRs and review requests |
| `/` | Search |
| `F` | Filter by repository |
| `S` | Sort |
| `I` | Show or hide inactive PRs |
| `R` | Show or hide recently opened PRs |
| `N` | Add a PR by link |
| `⇧M` | Choose the agent model and effort |
| `A` | Run the selected card's main action |
| `⇧A` | Summarize feedback or return a retained worktree |
| `C` | Copy the PR title and link |
| `M` | Merge, merge when ready or cancel a pending merge |
| `,` | Choose the repository's merge method |
| `U` | Update the branch |
| `⇧R` | Re-run failed checks |
| `Q` | Re-request review |
| `O` | Choose a clone or open a retained worktree |
| `Space` | Select cards for a batch action |
| `⇧X` | Select stale PRs |
| `X` | Remove an added review request or close selected stale PRs |
| `⌘R` | Refresh |
| `⌘⏎` | Confirm an inline question |
| `Esc` | Cancel, close or clear the selection |

### PR view

| Key | Action |
|---|---|
| `j` `k` | Next or previous step |
| `n` `p` | Next or previous suggested comment |
| `⏎` | Mark the step reviewed and move on |
| `⇧⏎` | Mark the whole change reviewed |
| `v` | Mark the whole file reviewed |
| `t` | Switch between Guided and Files |
| `/` | Search steps, files, comments and code |
| `s` | Show supporting changes |
| `o` | Open all supporting files |
| `c` | Comment on the current step |
| `a` `d` | Keep or dismiss a suggested comment |
| `i` | Show the PR description |
| `m` | Mark or unmark everything reviewed |
| `g` | Open the PR on GitHub |
| `⇧G` | Generate a guided review |
| `⇧M` | Choose the model, effort and lens |
| `r` | Open the review panel |
| `x` | Include or leave out the selected review comment |
| `a` | Include or exclude every review comment |
| `e` | Edit the review summary |
| `1` `2` `3` | Comment, Approve or Request changes |
| `⌘⏎` | Submit the review |
| `Esc` | Close the review panel |

### Fixes and agent review

On the fixes page, `j` and `k` move through requested changes, comments, failing checks and conflicts.
Use `R` to reply, `E` to resolve a thread, `⇧L` to open a check log, `⇧R` to re-run failed checks,
`G` to open GitHub's conflict editor and `B` to show bot comments. `Esc` returns to the hub with the
same card selected.

Reply and Resolve write to GitHub immediately. A reply posts after `⌘⏎`, and resolving a thread takes
effect as soon as you press `E`.

An agent fix opens in a review page before it can be pushed. `j` and `k` move between conflicts, `⏎`
marks one reviewed, `B` shows the original conflict, `P` pushes after every conflict is reviewed,
`D` asks to discard the fix and `Esc` returns to the board.

## Open a guide from another tool

The guide block is `prguide.guide`:

```lua
cx:new_block("prguide.guide", {"pr=123", "repo=/path/to/your/clone"}, "tab")
```

| Argument | Meaning |
|---|---|
| `repo=` | A path inside the repository clone |
| `pr=` | A PR number or URL |
| `guide=` | A saved guide JSON file; see [GUIDE.md](GUIDE.md) |
| `post=false` | Save the review under `/tmp` |
| `generate=true` | Start a guided review when the PR opens |

Behind the scenes, PR Guide fetches the PR into `refs/prguide/<number>/*` and leaves your branches and
working tree alone. For another repository, it keeps a light copy under Tern's plugin-data folder and
reuses it for later PRs.

Saved guides live at `.git/prguide/<number>.json`. Other tools can write the same format, documented
in [GUIDE.md](GUIDE.md).
