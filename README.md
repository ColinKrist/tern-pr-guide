# PR Guide

**A Tern plugin for tracking pull requests across repositories, reading their diffs and posting
reviews.**

Once you have a dozen PRs open across several repositories, keeping up with them turns into tab
management. CI results are on one GitHub page and review comments on another. The discussion is in
a Slack thread, and the fix you asked an agent for is in a separate conversation. To find out which
PRs need you, and why, you check each of them in turn.

PR Guide puts that work in Tern. The hub lists your PRs and review requests from every repository,
with the next action for each one. Open a PR to read the diff, have your own agent write a guided
walkthrough, comment on lines and submit the review to GitHub.

- **[PR Hub](#pr-hub)** sorts every PR you opened or were asked to review into columns by next
  action.
- **[PR View](#pr-view)** displays the description, changed files, comments and review panel in one
  Tern tab.
- **[Guided PR Diffs](#guided-pr-diffs)** present a large diff as an overview and a short series of
  steps, each pinned to its lines.
- **[AI Review](#ai-review)** generates that walkthrough with the model, effort and review lens you
  pick.

![The PR hub with pull requests in Needs fixes, In review and Ready to merge](docs/screenshots/hub.png)

## Install

PR Guide needs Tern and the [GitHub CLI](https://cli.github.com) signed in to GitHub.
[OMP](https://omp.sh) is optional. It runs guided reviews and agent fixes, and everything else
works without it.

```sh
gh auth login
tern plugin install github.com/jubbydev/tern-pr-guide
```

Press `⌥⌘R` in Tern, or choose **PR hub** from the command palette. To look around before pointing
it at real PRs, run **New PR hub sample block** for a board of recorded sample data, or **New PR
Guide sample block** for a sample PR whose review is a dry run.

To work on the plugin itself, clone it and run `tern plugin link /path/to/tern-pr-guide`.

## PR Hub

The hub has two tabs, switched with `T`. **Your pull requests** sorts your own PRs into **Needs
fixes**, **In review** and **Ready to merge**. **Review requests** sorts the PRs others asked you to
review into **To review**, **Waiting on author** and **Approved**. Each card includes the reason for
its column, such as requested changes, unresolved comments, failing checks, a conflict or a failed
merge-queue run.

The **Next up** bar above the board displays the most urgent PR. Press `.` to select it, `/` to
search across repositories, `F` to filter by repository and `S` to sort by repository, priority,
age or size. Routine card actions have their own keys: `M` to merge, `U` to update the branch, `⇧R`
to re-run failed checks and `Q` to re-request review.

To resolve a conflict or address a bot review, press `A` to hand the work to your OMP agent. The
agent works in an isolated worktree, and you can follow its progress on the card. Nothing is pushed
until you have reviewed the resulting commit and chosen to push it. For a PR tracked by Tandem,
pressing `A` sends it back to its Tandem coordinator instead.

The board loads from its cache and refreshes in the background when checks, comments or merge state
change. While the hub is open, a Tern status-line segment displays the number of PRs that need fixes
or review.

## PR View

Open a card to see the whole PR in Tern. For a PR that needs fixes, the first screen is the failing
check, comment or conflict. For a PR without a saved guide, the first screen contains its
description and the changed files as a folder tree. From there you can search the changed code,
comment on any changed line and submit a GitHub review.

![The PR file browser with the changed files and description](docs/screenshots/pr-view.png)

The diff comes from local git rather than GitHub, so GitHub's diff size limit doesn't apply, and
large PRs and long files stay responsive. PR Guide requests only changed data from GitHub: the hub
reads from its cache, checks the notifications endpoint with a conditional request and batches its
GraphQL queries. Measured usage is about 220 GraphQL points per hour while the hub is open, against
GitHub's limit of 5,000 per hour. Opening a PR fetches its metadata once, and the diff and source
come from local git.

## Guided PR Diffs

With OMP installed, you can have your agent write a guided review of the PR. The idea is close to
Linear Diffs: see the overall shape of the change first, then go through it in small pieces.

The first screen contains a plain-language overview and, for some PRs, a before-and-after diagram.
The PR is split into a few changes, and each change into steps. Each step's explanation appears
beside its lines. Press `j` and `k` to move between steps and `⏎` to mark the current one reviewed.

![A guided review with an overview, diagram and the first change](docs/screenshots/overview.png)

Each step contains its file list, removed and added lines, and any suggested comments next to the
relevant code. Press `t` at any point to switch between **Guided** and **Files**. Switching views
preserves comments, reviewed marks and the summary.

![A guided step with its code and a suggested review comment](docs/screenshots/step.png)

Guides are saved in the repository, so a reopened PR loads its guide right away, and every worktree
of the clone uses the same copy.

## AI Review

Before generating a guide, choose the model, effort and lens with `⇧M`. Pick a lens for the
review's focus:

- **Balanced**: a walkthrough of the whole PR with the comments worth making.
- **Security**: the change from an attacker's point of view.
- **Architecture**: boundaries, dependencies and long-term cost.
- **Quick skim**: the shape of the PR and only the most important comments.
- **Teaching**: explanations for someone new to the project.

![Choosing an OMP model, effort and review lens](docs/screenshots/lenses.png)

To add your own, choose **Edit lenses…** or press `⌃E`. Each custom lens is a Markdown file in your
lenses folder:

```markdown
# Performance

Slow paths and wasted work.

Check for repeated work in loops, unnecessary copying, blocking calls on hot paths and queries that
could be batched. Comment only when the cost will matter in practice.
```

A custom lens with the same name as a built-in one replaces it. The guide format is the same for
every lens, so PR View can open a guide written with any of them.

## Finish the review

The agent's comments are suggestions until you act on them. Press `a` to add one to your review or
`d` to dismiss it, and `c` to write your own on the current step. Press `r` to open the review
panel, pick Comment, Approve or Request changes with `1`, `2` or `3`, edit the summary and submit
everything as one GitHub review.

![The review panel with comments, summary and verdict](docs/screenshots/review.png)

Submitting takes two presses of `⌘⏎`. After the first, the review panel displays what will be
posted and where. The second press posts it, and any other key cancels. If the PR has new commits
since you started reading, submission stops until you refresh.

A dry run never writes to GitHub. The sample block and any guide opened with `post=false` save the
review to a JSON file under `/tmp` instead, and the review panel displays that destination before
you submit.

## A typical pass through the queue

1. Press `⌥⌘R` to focus the hub.
2. Press `.` to select the most urgent PR.
3. Use the card's action, or press `⏎` to open the PR.
4. Read with `j` and `k`, mark steps with `⏎` and add comments with `c`.
5. Press `r` to finish the review, then go back to the hub for the next card.

Press `⌥⇧⌘R` to open the hub in AI-guide mode, where `⏎` starts a guided review for any PR that
doesn't have a saved guide yet. `⇧⏎` does the same from any card.

## Keyboard reference

Press `?` on any PR Guide page for the shortcuts that apply there.

### PR hub

| Key | Action |
|---|---|
| `h` `j` `k` `l` or arrows | Move between cards |
| `.` | Select the most urgent PR |
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

On the fixes page, press `j` and `k` to move through requested changes, comments, failing checks
and conflicts. Press `R` to reply, `E` to resolve a thread, `⇧L` to open a check's log, `⇧R` to
re-run failed checks, `G` to open GitHub's conflict editor and `B` to show bot comments. `Esc`
returns you to the hub with the same card selected.

Replies and resolves write to GitHub right away. A reply posts when you press `⌘⏎`, and a thread is
resolved as soon as you press `E`.

An agent fix opens on a review page before you can push it. Press `j` and `k` to move between
conflicts, `⏎` to mark one reviewed and `B` to see the original conflict. Once every conflict is
reviewed, press `P` to push. `D` discards the fix after a confirmation, and `Esc` returns you to
the board.

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

PR Guide fetches the PR into `refs/prguide/<number>/*` and doesn't touch your branches or working
tree. When there's no local clone to use, it keeps a light copy under Tern's plugin-data folder and
reuses it for later PRs.

Saved guides are stored at `.git/prguide/<number>.json`. Any tool can write that format, which is
documented in [GUIDE.md](GUIDE.md).
