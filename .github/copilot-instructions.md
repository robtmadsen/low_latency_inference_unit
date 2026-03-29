# GitHub Copilot Instructions — LLIU

## Git Workflow

This repo uses **squash merge** for all PRs. Follow these rules on every new branch to avoid merge conflicts.

### Starting a new branch

Always branch off of `main`, never off of a feature branch:

```sh
git checkout main
git pull
git checkout -b feat/<topic>
```

### Before opening a PR

Verify the branch is based on the current tip of `main` and contains only the intended commits:

```sh
git log --oneline origin/main..HEAD
```

If the output includes commits that have already been merged (e.g. from a previous feature branch), rebase to remove them:

```sh
git rebase --onto origin/main <old-base-branch> <new-branch>
git push --force-with-lease
```

### After a PR lands

Delete the feature branch and start fresh from `main` for the next piece of work.
**One branch → one PR.** Never reuse a branch for a second PR.

```sh
git checkout main
git pull
git branch -d feat/<topic>                  # delete local branch
git push origin --delete feat/<topic>       # delete remote branch
git checkout -b feat/<next-topic>           # start next branch off updated main
```

If the remote branch is already gone (e.g. auto-deleted by GitHub), the last
`push --delete` step can be skipped.

### Why this matters

Squash merge creates a new SHA on `main` that is different from every commit on the original feature branch. Any branch started from that feature branch will carry those old commits in its ancestry. When the PR is opened, GitHub sees them as unmerged and reports conflicts.

Branching off `main` after a pull guarantees a clean merge every time.
