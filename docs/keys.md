# Keyboard reference

Every action in PR Guide has a key. Press `?` on any page for the shortcuts of that page.

## PR hub

| Key | Action |
|---|---|
| `⌥⌘R` | Open or focus the hub |
| `⌥⇧⌘R` | Open the hub so `⏎` generates the PR's guide |
| `h` `j` `k` `l` or arrows | Move between cards |
| `.` | Select the most urgent PR |
| `⏎` or click | Open the PR in the hub's own pane (a Needs fixes card opens its fixes page; a ready agent fix opens its review) |
| `⇧⏎` | Open the PR in the hub and generate its guide |
| `T` | Switch between your PRs and review requests |
| `/` | Search |
| `F` | Filter by repository or title; ignore named checks |
| `Tab` in a filter editor | Switch between text and options |
| `⏎` / `Space` in Filter | Edit / enable or disable a saved rule |
| `⏎` / `Esc` in a filter editor | Apply / return without saving |
| `S` | Sort |
| `I` | Show or hide inactive PRs, on either tab |
| `⇧T` | Show or hide team review requests |
| `A` | Show or hide approved PRs, on Review requests |
| `R` | Show or hide recently merged PRs, or recently opened PRs on Review requests |
| `N` | Add a PR by link |
| `⇧S` | Settings: the explanation and review models, their effort and the lens, in the same menu as the review page, and whether GitHub links open in Tern or the default browser (`L` switches while the search field is empty), whether AI guides are prepared in the background (`⇧G`), and auto-land's tries (`-` `+`) and dequeue label (`⇧D`, then `⏎` saves), while the search field is empty. `⇧M` opens it too |
| `A` | Run the selected card's main action, on your PRs |
| `⇧Q` | Turn auto-land on or off |
| `⇧A` | Summarize feedback or return a retained worktree |
| `C` | Copy the PR title as a link to the PR (a hyperlink when pasted into Slack; plain "title url" outside macOS) |
| `M` | Merge, merge when ready or cancel a pending merge |
| `,` | Choose the repository's merge method |
| `U` | Update the branch |
| `⇧R` | Re-run failed checks |
| `V` | Show the selected card's reviewers and checks: `j` `k` move through the checks, `⏎` opens a check, `Esc` closes |
| `Q` | Re-request review |
| `O` | Choose a clone or open a retained worktree |
| `⇧O` | Open agent chat: resume the agent's conversation after a conflict fix ends, or focus its pane when it is open |
| `Space` or ⌘-click | Select cards for a batch action |
| `⇧X` | Select stale PRs |
| `X` | Close the selected PR or the selected stale PRs, or remove an added review request |
| `⌘R` | Refresh |
| `⌘⏎` | Confirm an inline question |
| `Esc` | Cancel, close or clear the selection |
| `?` | Show shortcuts for the current hub page |

## PR view

| Key | Action |
|---|---|
| `j` `k` | Next or previous step |
| `n` `p` | Next or previous suggested comment |
| `⏎` | Mark the step reviewed and move on |
| `⇧⏎` | Mark the whole change reviewed |
| `f` | Mark the whole file reviewed |
| `t` | Switch between Guided and Files (in the hub, a Needs fixes PR also cycles Fixes) |
| `Esc` | In the hub, with nothing open on the page: back to the board |
| `⇧P` | Actions: in the hub Merge (or Merge when ready, Cancel merge) `M` and Update branch `U`, Re-request review `Q`; on every page Mark all reviewed `A`; in the hub Copy link `C`; on every page Open on GitHub `G`; in the hub Close pull request `X`. `j` `k` move, `⏎` or a row's letter runs it, `Esc` closes |
| `u` | In the hub: update the branch, when the PR offers Update branch |
| `v` | In the hub: the PR's reviewers and checks (`v` or `Esc` closes) |
| `b` | Hide or show the file tree in the file view |
| `/` | Search steps, files, comments and code |
| `s` | Show supporting changes |
| `o` | Open all supporting files and unfold Tests; generated files stay as they are |
| `⇧S` | Mark all supporting files reviewed |
| `c` | Comment on the current step |
| `a` `d` | Keep or dismiss a suggested comment |
| `i` | Show the PR description |
| `m` | Mark or unmark everything reviewed |
| `g` | Open the PR on GitHub |
| `⇧G` | Generate AI guide |
| `⇧R` | Generate LLM review |
| `⇧M` | Settings: the explanation and review models, their effort, and the lens |
| `⇧L` | Choose the review lens |
| `Tab` | In that menu, switch between Explanation, Review and Lens |
| `⌃E` | Edit lenses |
| `r` | Open the review panel |
| `x` | Include or leave out the selected review comment |
| `a` | Include or exclude every review comment |
| `e` | Edit the review summary |
| `1` `2` `3` | Comment, Approve or Request changes |
| `⌘⏎` | Submit the review |
| `Esc` | Close the review panel |

## Fixes page

Replies and resolves write to GitHub right away.

| Key | Action |
|---|---|
| `j` `k` | Move through requested changes, comments, failing checks and conflicts |
| `R` | Reply to the thread |
| `⌘⏎` | Post the reply |
| `E` | Resolve the thread |
| `⇧L` | Open the check's log |
| `⇧R` | Re-run failed checks |
| `U` | Update branch, or push an empty commit when the branch is up to date (`⌘⏎` confirms) |
| `V` | Show all checks |
| `⇧P` | The Pull request menu: merge, close and the PR's other actions |
| `t` | Next view: Fixes, Guided, Files |
| `G` | Open GitHub's conflict editor |
| `B` | Show bot comments |
| `⇧O` | Open agent chat, after an agent fix ends |
| `Esc` | Back to the hub with the same card selected |
| `?` | Show shortcuts for the fixes page |

## Agent fix review

| Key | Action |
|---|---|
| `j` `k` | Move between conflicts |
| `⏎` | Mark the conflict reviewed |
| `B` | Show the original conflict |
| `P` | Push, once every conflict is reviewed |
| `D` | Discard the fix, after a confirmation |
| `⇧O` | Open agent chat in the fix worktree |
| `Esc` | Back to the hub |
| `?` | Show shortcuts for Review fix |

