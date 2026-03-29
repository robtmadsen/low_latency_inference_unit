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

### Why this matters

Squash merge creates a new SHA on `main` that is different from every commit on the original feature branch. Any branch started from that feature branch will carry those old commits in its ancestry. When the PR is opened, GitHub sees them as unmerged and reports conflicts.

Branching off `main` after a pull guarantees a clean merge every time.
