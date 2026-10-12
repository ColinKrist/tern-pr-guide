# Review lenses

A lens steers the review comments only: what the AI reviewer looks for and how it words them. The
explanation of the PR is the same whatever the lens. Choose one on the Review slot of the model
menu (click the model, or press ⇧M, then Tab) before you generate a review.

Each other `.md` file in a lenses folder is one lens:

```markdown
# Performance

One line saying what this lens is for. This shows in the menu.

Everything from here on is what the reviewer is told. Write it like you'd brief a colleague:
what to look for, what to ignore, how to word comments and the summary.
```

- The first `# Heading` is the lens's name. Files that don't start with one are skipped.
- The first paragraph under it is the description, the rest is the instructions.
- The comments are still written in the same format, whatever the lens says.
- A file named like a built-in lens (Security, say) replaces it.
- This README isn't a lens.

To add your own, choose **Edit lenses…** in the model menu. It opens your lenses folder, and the
new lens shows up the next time you open the menu.
